import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_db.dart';

/// Bulut bağlantı rozeti durumu.
enum CloudMode { off, online, offline, syncing, error }

class CloudStatus {
  final CloudMode mode;
  final int pending;
  final String? message;
  const CloudStatus({required this.mode, this.pending = 0, this.message});
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
  bool _running = false;

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
    await _onConnectivity(initial: true);
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
      _set(CloudStatus(mode: cur.mode, pending: p));
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
      _set(CloudStatus(mode: CloudMode.online, pending: p));
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

  String _remote(String entity) => entity; // birebir tablo adları

  /// Son push turunda takılan ilk işlemin hatası (tanı için saklanır).
  String? lastPushError;

  Future<void> _push() async {
    final db = _db!, sb = _sb!;
    lastPushError = null;
    var ops = await db.pendingOps(limit: 200);
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
          lastPushError =
              '[${op.entity}:${op.rowUuid}] ${e.toString().split('\n').first}';
          await db.bumpAttempts(op.id);
          failed = true;
          break; // ilk hatada dur, sonrakiler sonraki turda
        }
      }
      await db.dropOps(done);
      if (failed) break;
      ops = await db.pendingOps(limit: 200);
    }
  }

  /// Push'ta benzersizlik çakışması (409/23505): bulutun kazanan
  /// kaydını benimseyip kuyruğu onarır. Başarılıysa true.
  Future<bool> _resolveConflict(QueuedOp op, Object e) async {
    final msg = e.toString();
    if (!msg.contains('23505') && !msg.contains('duplicate key')) {
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

    // Değişmezler: imleçten sonrası.
    Future<List> since(String table, String col) async {
      final cur = await db.lastPulled(table);
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
