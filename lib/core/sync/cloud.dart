import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_db.dart';

/// Bulut bağlantı rozeti durumu.
enum CloudMode { off, online, offline, syncing, error }

class CloudStatus {
  final CloudMode mode;
  final int pending;
  final String? message;

  /// Son başarılı senkronun saati (canlı kanıtı).
  final DateTime? syncedAt;
  const CloudStatus(
      {required this.mode,
      this.pending = 0,
      this.message,
      this.syncedAt});
}

/// İmleç örtüşmesi: saat farkı (telefon-PC) + çekiş sırası yarışı
/// yüzünden imlecin biraz gerisinde kalan satırlar kaybolmasın diye
/// 10 dk geriden çekilir. Uygulama uuid-idempotent, tekrar zararsız.
DateTime? overlapCutoff(DateTime? cursor) =>
    cursor?.subtract(const Duration(minutes: 10));

/// Push sırası: üst satırlar (kategori/tedarikçi) önce itilir,
/// yoksa bulut FK hatası verir. Kuyruk id sırası bunu garanti etmez
/// (birleştirme sonradan satır ekleyebilir), o yüzden açık sıralanır.
int pushRank(String entity) => switch (entity) {
      'categories' || 'suppliers' || 'expenses' => 0,
      'products' => 1,
      'sales' => 2,
      'sale_items' || 'stock_movements' => 3,
      _ => 9,
    };

/// Benzersizlik çakışması mı? (409 / 23505)
bool _isConflict(Object e) {
  final msg = e.toString();
  return msg.contains('23505') || msg.contains('duplicate key');
}

/// Rozet bu dinleyiciyle beslenir (anashell üst barı).
final cloudStatus =
    ValueNotifier<CloudStatus>(const CloudStatus(mode: CloudMode.off));

/// Faz-3 senkron motoru (offline-first + outbox kuyruğu).
/// Kurallar:
/// - Fiş/hareket/gider DEĞİŞMEZ: uuid ile bir-kez uygulanır.
/// - Ürün/kategori LWW (updated_at); mevcut üründe stok HARİÇ alınır.
/// - Stok sadece hareket deltalarıyla yürür (yeni üründe snapshot).
class Cloud {
  static final Cloud instance = Cloud._();
  Cloud._();

  AppDb? _db;
  SupabaseClient? _sb;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _periodic;
  bool _running = false;
  bool _resumedOnce = false;

  static const kUrl = 'sb_url';
  static const kKey = 'sb_key';
  static const kDevice = 'device_code';

  bool get isConfigured => _sb != null;
  bool get isAuthed => _sb?.auth.currentUser != null;
  String? get userEmail => _sb?.auth.currentUser?.email;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<String> deviceCode() async =>
      (await _prefs).getString(kDevice) ?? 'K1';

  Future<void> setDeviceCode(String code) async {
    (await _prefs).setString(kDevice, code);
    _db?.deviceCode = code;
  }

  Future<Map<String, String?>> savedConfig() async {
    final p = await _prefs;
    return {'url': p.getString(kUrl), 'key': p.getString(kKey)};
  }

  /// Supabase Project URL biçimi: https://xyz.supabase.co
  /// (sonunda / yok, ek yol yok, dashboard adresi değil).
  static String? normalizeSupabaseUrl(String input) {
    // Mobil klavyeler ilk harfi büyütebilir / boşluk ekleyebilir:
    var u = input.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    if (RegExp(r'^https://[a-z0-9-]+\.supabase\.co$').hasMatch(u)) {
      return u;
    }
    return null;
  }

  static const urlHelp =
      'URL hatalı görünüyor. Doğrusu şuna benzer: https://xyz.supabase.co '
      '(sonunda / veya ek yol olmadan, tarayıcıdaki dashboard adresi değil). '
      'Supabase → Project Settings → Data API → Project URL.';

  /// Hata metni döner (null = kaydedildi).
  Future<String?> saveConfig(String url, String key) async {
    final clean = normalizeSupabaseUrl(url);
    if (clean == null) return urlHelp;
    if (key.trim().isEmpty) return 'Anon key boş olamaz.';
    final p = await _prefs;
    await p.setString(kUrl, clean);
    await p.setString(kKey, key.trim());
    return null;
  }

  /// Açılışta bir kez çağrılır. Yapılandırma yoksa sessizce kapalı kalır.
  Future<void> init(AppDb db) async {
    _db = db;
    final p = await _prefs;
    db.deviceCode = p.getString(kDevice) ?? 'K1';
    final url = p.getString(kUrl);
    final key = p.getString(kKey);
    if (url == null ||
        url.isEmpty ||
        key == null ||
        key.isEmpty ||
        normalizeSupabaseUrl(url) == null) {
      _set(const CloudStatus(mode: CloudMode.off));
      return;
    }
    try {
      await Supabase.initialize(url: url, anonKey: key);
    } catch (_) {
      // Zaten init edilmiş olabilir; client yine alınır.
    }
    try {
      _sb = Supabase.instance.client;
    } catch (_) {
      _sb = null;
    }
    final sb = _sb;
    if (sb == null) {
      _set(const CloudStatus(
          mode: CloudMode.error, message: 'Supabase açılamadı'));
      return;
    }
    await _connSub?.cancel();
    _connSub = Connectivity()
        .onConnectivityChanged
        .listen((_) => _onConnectivity());
    // Oturum değişince rozet/kart kendini güncellesin:
    sb.auth.onAuthStateChange.listen((_) => refreshPending());
    // Sürekli senkron: kaçan realtime olayı + uyku sonrası için
    // 45 sn'de bir yoklama (çevrimiçi + giriş varsa).
    _periodic?.cancel();
    _periodic = Timer.periodic(
        const Duration(seconds: 45), (_) => _periodicTick());
    // Uygulamaya dönüşte hemen tazele (tek seferlik kayıt):
    if (!_resumedOnce) {
      _resumedOnce = true;
      WidgetsBinding.instance.addObserver(_ResumeSync());
    }
    await _onConnectivity(initial: true);
  }

  Future<void> _periodicTick() async {
    if (_running || !isAuthed) return;
    try {
      final r = await Connectivity().checkConnectivity();
      if (r.contains(ConnectivityResult.none)) return;
    } catch (_) {
      return;
    }
    await syncNow();
  }

  Future<void> _onConnectivity({bool initial = false}) async {
    final r = await Connectivity().checkConnectivity();
    final online = !r.contains(ConnectivityResult.none);
    if (!online) {
      final p = _db == null ? 0 : await _db!.pendingCount();
      _set(CloudStatus(mode: CloudMode.offline, pending: p));
      return;
    }
    if (isAuthed) {
      await syncNow();
    } else if (_db != null) {
      final p = await _db!.pendingCount();
      _set(CloudStatus(mode: CloudMode.online, pending: p));
    }
    if (initial && isAuthed) await refreshPending();
  }

  /// Giriş: önce sign-in, hesap yoksa sign-up dener. Hata metni döner.
  /// Sign-up e-posta onayı beklerse oturum açılmaz — bunu açıkça söyler.
  Future<String?> signIn(String email, String password) async {
    if (_sb == null) {
      return 'Önce Supabase URL + anahtar kaydedin. $urlHelp';
    }
    try {
      await _sb!.auth.signInWithPassword(
          email: email.trim(), password: password);
    } on AuthException catch (firstErr) {
      try {
        await _sb!.auth
            .signUp(email: email.trim(), password: password);
      } on AuthException catch (e) {
        final m = e.message.toLowerCase();
        if (m.contains('already registered') ||
            m.contains('already exists') ||
            m.contains('already been registered')) {
          return 'Bu e-posta kayıtlı ama giriş olmadı — şifreni kontrol et. '
              '(Şifreyi unuttuysan Supabase → Authentication → Users → ilgili kullanıcı → Reset password.)';
        }
        return e.message;
      } catch (_) {
        // sign-in hatası varken sign-up da bilinmez şekilde patladıysa
        // asıl hatayı göster:
        return firstErr.message;
      }
    } catch (e) {
      return e.toString().split('\n').first;
    }
    if (!isAuthed) {
      return 'Hesap var ama oturum açılamadı: büyük ihtimal e-posta onayı bekleniyor. '
          'Supabase → Authentication → Users → ilgili kullanıcı → Confirm email yapın '
          '(veya Authentication → Sign In/Up ayarlarından "Confirm email"i kapatın).';
    }
    await syncNow();
    return null;
  }

  Future<void> signOut() async {
    await _sb?.auth.signOut();
    _set(const CloudStatus(mode: CloudMode.online));
  }

  Future<void> refreshPending() async {
    if (_db == null) return;
    final p = await _db!.pendingCount();
    final cur = cloudStatus.value;
    if (cur.mode != CloudMode.syncing) {
      _set(CloudStatus(
          mode: cur.mode, pending: p, syncedAt: cur.syncedAt));
    }
  }

  /// Tanı kartı: yerel vs bulut sayaçları + imleçler + son hata.
  /// Hangi tarafın bozuk olduğunu tek bakışta gösterir.
  Future<Map<String, String>> debugInfo() async {
    final out = <String, String>{};
    out['cihaz'] = _db?.deviceCode ?? '?';
    out['eposta'] = userEmail ?? '-';
    if (_db != null) {
      final db = _db!;
      out['yerel_urun'] =
          '${(await db.select(db.products).get()).length}';
      out['yerel_satis'] =
          '${(await db.select(db.sales).get()).length}';
      out['yerel_hareket'] =
          '${(await db.select(db.stockMovements).get()).length}';
      out['kuyruk'] = '${await db.pendingCount()}';
      out['son_cekis'] = '${await db.lastPulled('sales')}';
    }
    if (_sb != null && isAuthed) {
      try {
        out['bulut_urun'] = '${await _sb!.from('products').count()}';
        out['bulut_satis'] = '${await _sb!.from('sales').count()}';
        out['bulut_hareket'] =
            '${await _sb!.from('stock_movements').count()}';
      } catch (e) {
        out['bulut_hata'] = e.toString().split('\n').first;
      }
    } else {
      out['bulut'] = 'giriş yok';
    }
    if (lastPushError != null) out['push_hata'] = lastPushError!;
    final m = cloudStatus.value.message;
    if (m != null) out['son_hata'] = m;
    final sa = cloudStatus.value.syncedAt;
    if (sa != null) out['son_senkron'] = sa.toString();
    return out;
  }

  /// Kurtarma: tüm yerel veriyi kuyruğa kur + hemen senkronla.
  /// Dönen sayı kuyruğa yazılan satırdır.
  Future<int> requeueAndSync() async {
    if (_db == null) return 0;
    final n = await _db!.requeueAll();
    await refreshPending();
    await syncNow();
    return n;
  }

  Future<void> syncNow() async {
    if (_running || _db == null || _sb == null || !isAuthed) return;
    _running = true;
    _set(const CloudStatus(mode: CloudMode.syncing));
    try {
      // İlk eşleşme: imleçler boşsa tüm yerel veri kuyruğa kurulur
      // (eski kayıtlar + başka sürümden kalanlar dahil).
      if (await _db!.lastPulled('sales') == null) {
        await _db!.requeueAll();
      }
      await _push();
      await _pull();
      _subscribe();
      final p = await _db!.pendingCount();
      _set(CloudStatus(
          mode: CloudMode.online, pending: p, syncedAt: DateTime.now()));
    } catch (e) {
      final p = await _db!.pendingCount();
      _set(CloudStatus(
          mode: CloudMode.error,
          pending: p,
          message: e.toString().split('\n').first));
    } finally {
      _running = false;
    }
  }

  // ================= PUSH =================

  /// Son push turunda takılan ilk işlemin hatası (tanı için saklanır).
  String? lastPushError;

  String _remote(String entity) => entity; // birebir tablo adları

  Future<void> _push() async {
    final db = _db!, sb = _sb!;
    lastPushError = null;
    var ops = await db.pendingOps(limit: 200);
    // FK sırası: üst satırlar önce (kategori -> ürün -> satış -> satır).
    ops.sort((a, b) {
      final r = pushRank(a.entity).compareTo(pushRank(b.entity));
      return r != 0 ? r : a.id.compareTo(b.id);
    });
    // Senkron başına op başına en fazla 2 iyileştirme (kısır döngü
    // yok; attempts freni bilerek YOK çünkü eski sürümde şişmiş
    // sayaçlar iyileşmeyi sonsuza dek engelliyordu).
    final heals = <int, int>{};
    while (ops.isNotEmpty) {
      final done = <int>[];
      var failed = false;
      for (final op in ops) {
        try {
          final payload =
              jsonDecode(op.payload) as Map<String, dynamic>;
          await sb
              .from(_remote(op.entity))
              .upsert(payload, onConflict: 'uuid');
          done.add(op.id);
        } catch (e) {
          // Çift kayıt çakışması çözülebilirse kuyrukta takılma:
          if (await _resolveConflict(op, e)) {
            await db.dropOps([op.id]);
            continue;
          }
          // Eksik üst satır (FK 23503): önce onu it, bunu yeniden dene.
          final n = heals[op.id] ?? 0;
          if (n < 2 && await _pushMissingParent(op, e)) {
            heals[op.id] = n + 1;
            continue;
          }
          lastPushError =
              '[${op.entity}:${op.rowUuid}] ${e.toString().split('\n').first}${await _fkVerdict(op, e)}';
          await db.bumpAttempts(op.id);
          failed = true;
          break; // ilk hatada dur, sonrakiler sonraki turda
        }
      }
      await db.dropOps(done);
      if (failed) break;
      ops = await db.pendingOps(limit: 200);
      ops.sort((a, b) {
        final r = pushRank(a.entity).compareTo(pushRank(b.entity));
        return r != 0 ? r : a.id.compareTo(b.id);
      });
    }
  }

  /// FK hatasında hüküm cümlesi: referans yerelde var mı, bulutta var mı?
  /// Tanı kartında görünür, kör tahmin biter.
  Future<String> _fkVerdict(QueuedOp op, Object e) async {
    final msg = e.toString();
    if (!msg.contains('23503') && !msg.contains('foreign key')) return '';
    final db = _db!, sb = _sb!;
    try {
      final payload = jsonDecode(op.payload) as Map<String, dynamic>;
      // Hangi referanslar var? (entity'ye göre)
      final refs = <String, String>{}; // tablo -> uuid
      if (op.entity == 'products') {
        final c = payload['category_uuid'] as String?;
        final s = payload['supplier_uuid'] as String?;
        if (c != null) refs['categories'] = c;
        if (s != null) refs['suppliers'] = s;
      } else if (op.entity == 'sale_items') {
        final s = payload['sale_uuid'] as String?;
        final p = payload['product_uuid'] as String?;
        if (s != null) refs['sales'] = s;
        if (p != null) refs['products'] = p;
      } else if (op.entity == 'stock_movements') {
        final p = payload['product_uuid'] as String?;
        if (p != null) refs['products'] = p;
      } else {
        return '';
      }
      if (refs.isEmpty) return ' (boş referans)';
      final parts = <String>[];
      for (final entry in refs.entries) {
        final table = entry.key;
        final uuid = entry.value;
        var local = '?';
        try {
          final row = await sb
              .from(table)
              .select('uuid')
              .eq('uuid', uuid)
              .maybeSingle();
          // Yerel kontrol tabloya göre:
          var lfound = false;
          if (table == 'categories') {
            lfound = await (db.select(db.categories)
                      ..where((t) => t.uuid.equals(uuid)))
                    .getSingleOrNull() !=
                null;
          } else if (table == 'suppliers') {
            lfound = await (db.select(db.suppliers)
                      ..where((t) => t.uuid.equals(uuid)))
                    .getSingleOrNull() !=
                null;
          } else if (table == 'products') {
            lfound = await db.productByUuid(uuid) != null;
          } else if (table == 'sales') {
            lfound = await (db.select(db.sales)
                      ..where((t) => t.uuid.equals(uuid)))
                    .getSingleOrNull() !=
                null;
          }
          local = lfound ? 'VAR' : 'YOK';
          final short =
              uuid.length <= 8 ? uuid : uuid.substring(0, 8);
          parts.add(
              '$table=$short: localde $local, bulutta ${row == null ? 'YOK' : 'VAR'}');
        } catch (_) {
          parts.add('$table: bakılamadı');
        }
      }
      return ' | FK: ${parts.join('; ')}';
    } catch (_) {
      return '';
    }
  }

  /// FK 23503: satırın bağlı olduğu üst satır bulutta yoksa önce
  /// onu iter. Başarılıysa true (mevcut op yeniden denensin).
  /// Ayrıca ürün op'ları canlı satırdan tazelenir (bayat category_uuid
  /// gibi referanslar onarılır), canlı satırı kalmayan öksüz op düşer.
  Future<bool> _pushMissingParent(QueuedOp op, Object e) async {
    final db = _db!;
    // 1) Bayatlık onarımı (hata tipinden bağımsız):
    if (op.entity == 'products' && await db.refreshProductOp(op)) {
      return true; // tazelendi/öksüz düştü, yeniden denenecek
    }
    final msg = e.toString();
    if (!msg.contains('23503') && !msg.contains('foreign key')) {
      return false;
    }
    final sb = _sb!;
    try {
      final payload = jsonDecode(op.payload) as Map<String, dynamic>;
      if (op.entity == 'products') {
        for (final parent in ['categories', 'suppliers']) {
          final key =
              parent == 'categories' ? 'category_uuid' : 'supplier_uuid';
          final pu = payload[key] as String?;
          if (pu == null) continue;
          Map<String, dynamic>? parentPayload;
          String? parentName;
          if (parent == 'categories') {
            final c = await (db.select(db.categories)
                  ..where((t) => t.uuid.equals(pu)))
                .getSingleOrNull();
            if (c == null) return false;
            parentPayload = db.categoryPayload(c);
            parentName = c.name;
          } else {
            final s = await (db.select(db.suppliers)
                  ..where((t) => t.uuid.equals(pu)))
                .getSingleOrNull();
            if (s == null) return false;
            parentPayload = db.supplierPayload(s);
          }
          try {
            await sb
                .from(parent)
                .upsert(parentPayload, onConflict: 'uuid');
          } catch (pe) {
            // Üst satır ada takıldıysa (başka uuid ile aynı ad):
            // bulutun kazananını benimse, kuyruk onarılır.
            if (!_isConflict(pe) || parent != 'categories') {
              return false;
            }
            final existing = await sb
                .from('categories')
                .select()
                .eq('name', parentName!)
                .maybeSingle();
            if (existing == null) return false;
            final winner =
                Map<String, dynamic>.from(existing as Map);
            await db.adoptCategoryUuid(pu, winner['uuid'] as String);
          }
        }
        return true;
      }
      if (op.entity == 'sale_items') {
        final su = payload['sale_uuid'] as String?;
        if (su == null) return false;
        final sale = await (db.select(db.sales)
              ..where((t) => t.uuid.equals(su)))
            .getSingleOrNull();
        if (sale == null) return false;
        try {
          await sb
              .from('sales')
              .upsert(db.salePayload(sale), onConflict: 'uuid');
        } catch (pe) {
          // Fiş no çakışması: aynı uuid ise sorun yok, farklı uuid ise
          // iki cihazda aynı K kodu kullanılıyor demektir.
          if (!_isConflict(pe)) return false;
          final existing = await sb
              .from('sales')
              .select('uuid')
              .eq('receipt_no', sale.receiptNo)
              .maybeSingle();
          if (existing == null) return false;
          final winner =
              Map<String, dynamic>.from(existing as Map);
          if (winner['uuid'] != su) return false;
        }
        return true;
      }
      if (op.entity == 'stock_movements') {
        final pu = payload['product_uuid'] as String?;
        if (pu == null) return false;
        final prod = await db.productByUuid(pu);
        if (prod == null) return false;
        await sb
            .from('products')
            .upsert(await db.productPayload(prod), onConflict: 'uuid');
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Push'ta benzersizlik çakışması (409/23505): bulutun kazanan
  /// kaydını benimseyip kuyruğu onarır. Başarılıysa true.
  Future<bool> _resolveConflict(QueuedOp op, Object e) async {
    if (!_isConflict(e)) {
      return false;
    }
    final db = _db!, sb = _sb!;
    try {
      final payload = jsonDecode(op.payload) as Map<String, dynamic>;
      if (op.entity == 'categories') {
        final name = payload['name'] as String?;
        if (name == null) return false;
        final existing = await sb
            .from('categories')
            .select()
            .eq('name', name)
            .maybeSingle();
        if (existing == null) return false;
        final winner =
            Map<String, dynamic>.from(existing as Map);
        await db.adoptCategoryUuid(
            payload['uuid'] as String, winner['uuid'] as String);
        return true;
      }
      if (op.entity == 'products') {
        final barcode = payload['barcode'] as String?;
        if (barcode == null || barcode.isEmpty) return false;
        final existing = await sb
            .from('products')
            .select()
            .eq('barcode', barcode)
            .maybeSingle();
        if (existing == null) return false;
        final winner =
            Map<String, dynamic>.from(existing as Map);
        await db.adoptProductUuid(
            payload['uuid'] as String, winner['uuid'] as String);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  // ================= PULL =================

  Map<String, dynamic> _m(dynamic e) =>
      Map<String, dynamic>.from(e as Map);

  Future<void> _pull() async {
    final db = _db!, sb = _sb!;
    db.beginPullBatch();
    final now = DateTime.now();

    // Sözlükler: tam çekiş + LWW (küçük tablolar).
    for (final row in await sb.from('categories').select()) {
      await db.applyCategory(_m(row));
    }
    for (final row in await sb.from('suppliers').select()) {
      final m = _m(row);
      final uuid = m['uuid'] as String;
      // Tedarikçi LWW: applyCategory benzeri sade upsert
      await db.applySupplierLike(uuid, m);
    }
    for (final row in await sb.from('products').select()) {
      final m = _m(row);
      final wasNew =
          await db.productByUuid(m['uuid'] as String) == null;
      await db.applyProduct(m);
      if (wasNew) {
        final p = await db.productByUuid(m['uuid'] as String);
        if (p != null) db.markProductFresh(p.id);
      }
    }

    // Değişmezler: imleçten sonrası (10 dk örtüşmeli — saat farkı
    // ve çekiş-sırası yarışında satır kaybolmasın; uuid-idempotent).
    Future<List> since(String table, String col) async {
      final cur = overlapCutoff(await db.lastPulled(table));
      if (cur == null) {
        return await sb.from(table).select().order(col);
      }
      return await sb
          .from(table)
          .select()
          .gt(col, cur.toIso8601String())
          .order(col);
    }

    for (final s in await since('sales', 'date')) {
      final sm = _m(s);
      final items = await sb
          .from('sale_items')
          .select()
          .eq('sale_uuid', sm['uuid']);
      await db.applySaleDoc(
          sm, items.map(_m).toList());
    }
    for (final mv in await since('stock_movements', 'date')) {
      final mm = _m(mv);
      await db.applyMovement(mm, mm['product_uuid'] as String? ?? '');
    }
    for (final ex in await since('expenses', 'date')) {
      await db.applyExpense(_m(ex));
    }

    await db.savePulled('sales', now);
    await db.savePulled('stock_movements', now);
    await db.savePulled('expenses', now);
  }

  // ================= REALTIME =================

  void _subscribe() {
    if (_channel != null || _sb == null) return;
    const tables = [
      'categories',
      'suppliers',
      'products',
      'stock_movements',
      'sales',
      'sale_items',
      'expenses',
    ];
    var ch = _sb!.channel('kirtasiye');
    for (final t in tables) {
      ch = ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: t,
        callback: (_) => _debouncedPull(),
      );
    }
    _channel = ch..subscribe();
  }

  void _debouncedPull() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      if (!_running && isAuthed) syncNow();
    });
  }

  void _set(CloudStatus s) => cloudStatus.value = s;
}

/// Uygulamaya dönüşte (arka plandan) hemen senkronla.
class _ResumeSync with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Cloud.instance.syncNow();
    }
  }
}

/// FutureBuilder'lı ekranlar için otomatik tazeleme:
/// senkron bitince yeniden sorgular. Sekmeye dönüş tazeliği için
/// ekran `active` parametresi + didUpdateWidget ile setState yapar.
mixin SyncRefreshMixin<T extends StatefulWidget> on State<T> {
  bool _wasSyncing = false;

  @override
  void initState() {
    super.initState();
    _wasSyncing = cloudStatus.value.mode == CloudMode.syncing;
    cloudStatus.addListener(_onCloud);
  }

  @override
  void dispose() {
    cloudStatus.removeListener(_onCloud);
    super.dispose();
  }

  void _onCloud() {
    final syncing = cloudStatus.value.mode == CloudMode.syncing;
    if (_wasSyncing && !syncing && mounted) setState(() {});
    _wasSyncing = syncing;
  }
}
