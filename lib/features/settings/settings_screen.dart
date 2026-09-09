import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/sync/cloud.dart';

/// Yedekleme + bulut senkron + donanım + bilgi ekranı.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('KırtasiyePOS • Ayarlar')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const CloudCard(),
          const DiagCard(),
          Card(
            child: ListTile(
              leading: const Icon(Icons.backup),
              title: const Text('Veritabanını Yedekle'),
              subtitle: const Text(
                  'kirtasiye.db dosyasının tarihli kopyasını Belgeler’e alır'),
              onTap: () => _backup(context),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Veri Klasörünü Göster'),
              subtitle: FutureBuilder<String>(
                future: _dbPath(),
                builder: (_, s) => Text(s.data ?? '...'),
              ),
            ),
          ),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.print),
              title: const Text('Yazıcılar (Faz-2)'),
              subtitle: const Text(
                  'Fiş ve etiketler sistem yazıcısına basılır'),
              children: [
                FutureBuilder<List<Printer>>(
                  future: Printing.listPrinters(),
                  builder: (_, snap) {
                    if (snap.hasError) {
                      return ListTile(
                          title: Text('Liste alınamadı: ${snap.error}'));
                    }
                    if (!snap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                            child: CircularProgressIndicator()),
                      );
                    }
                    final printers = snap.data!;
                    if (printers.isEmpty) {
                      return const ListTile(
                          title: Text(
                              'Yazıcı bulunamadı — Windows’a yazıcı ekleyin.'));
                    }
                    return Column(
                      children: [
                        ...printers.map((pr) => ListTile(
                              dense: true,
                              leading: const Icon(
                                  Icons.print_outlined,
                                  size: 20),
                              title: Text(pr.name),
                              subtitle: Text(
                                  '${pr.model ?? ''} • ${pr.location ?? ''} • ${pr.isDefault ? 'Varsayılan' : ''}'),
                            )),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: FilledButton.tonalIcon(
                            onPressed: () =>
                                _testPrint(context),
                            icon: const Icon(Icons.receipt_long),
                            label:
                                const Text('Test Sayfası Yazdır'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('KırtasiyePOS v0.2 (Faz-2 ✅)'),
              subtitle: Text(
                  'Tek kasa • Offline • SQLite\n'
                  'Faz-1: stok, satış, KDV, ciro, kar, rapor.\n'
                  'Faz-2: USB barkod okuyucu (hazır, Enter’lı), '
                  'mobil kamera tarama (APK’da), dahili barkod üretme, '
                  'raf etiketi + 80mm fiş baskısı.'),
            ),
          ),
        ],
      ),
    );
  }

  Future<String> _dbPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'kirtasiye', 'kirtasiye.db');
  }

  Future<void> _backup(BuildContext context) async {
    try {
      final src = File(await _dbPath());
      if (!await src.exists()) {
        throw 'Veritabanı henüz oluşmamış (bir satış/ürün kaydedin).';
      }
      final dir = await getApplicationDocumentsDirectory();
      final stamp =
          DateTime.now().toIso8601String().replaceAll(':', '-');
      final dst =
          File(p.join(dir.path, 'kirtasiye', 'yedek_$stamp.db'));
      await src.copy(dst.path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Yedek alındı: ${dst.path}')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Yedek hatası: $e')));
      }
    }
  }

  Future<void> _testPrint(BuildContext context) async {
    try {
      final doc = pw.Document();
      doc.addPage(
        pw.Page(
          build: (_) => pw.Center(
            child: pw.Column(
              mainAxisAlignment:
                  pw.MainAxisAlignment.center,
              children: [
                pw.Text('KIRTASIYEPOS',
                    style: pw.TextStyle(
                        font: pw.Font.helveticaBold(),
                        fontSize: 24)),
                pw.SizedBox(height: 8),
                pw.Text(
                    'Test sayfası — yazıcı bağlantısı çalışıyor.'),
                pw.SizedBox(height: 8),
                pw.BarcodeWidget(
                  barcode: pw.Barcode.code128(),
                  data: 'TEST-123456',
                  width: 200,
                  height: 60,
                ),
              ],
            ),
          ),
        ),
      );
      await Printing.layoutPdf(
        onLayout: (_) async => doc.save(),
        name: 'kirtasiye_test',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Yazdırma hatası: $e')));
      }
    }
  }
}

/// Bulut senkron kartı (Faz-3): Supabase bağlantısı + giriş + kasa kodu.
class CloudCard extends StatefulWidget {
  const CloudCard({super.key});
  @override
  State<CloudCard> createState() => _CloudCardState();
}

class _CloudCardState extends State<CloudCard> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _device = TextEditingController(text: 'K1');
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await Cloud.instance.savedConfig();
    _url.text = cfg['url'] ?? '';
    _key.text = cfg['key'] ?? '';
    _device.text = await Cloud.instance.deviceCode();
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _email.dispose();
    _pass.dispose();
    _device.dispose();
    super.dispose();
  }

  void _msg(String t, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(t),
      backgroundColor: err ? Colors.red.shade700 : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Card(
          child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator())));
    }
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.cloud_sync),
        title: const Text('Bulut Senkron (telefon + PC)'),
        subtitle: ValueListenableBuilder<CloudStatus>(
          valueListenable: cloudStatus,
          builder: (_, s, child) {
            final authed = Cloud.instance.isAuthed;
            final email = Cloud.instance.userEmail;
            return Text(
              switch (s.mode) {
                CloudMode.off =>
                  'Kapalı — URL + anahtar gerekli',
                CloudMode.online => authed
                    ? 'Çevrimiçi • $email'
                    : 'Çevrimiçi • giriş gerekli',
                CloudMode.offline =>
                  'Çevrimdışı • ${s.pending} bekliyor',
                CloudMode.syncing =>
                  'Senkronize ediliyor...',
                CloudMode.error =>
                  'Hata: ${s.message ?? ''}',
              },
            );
          },
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                      labelText: 'Supabase URL',
                      hintText: 'https://xyz.supabase.co',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _key,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Supabase anon key',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _device,
                        maxLength: 3,
                        decoration: const InputDecoration(
                            labelText: 'Kasa kodu',
                            hintText: 'K1 / K2',
                            border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _email,
                        keyboardType:
                            TextInputType.emailAddress,
                        decoration: const InputDecoration(
                            labelText: 'E-posta',
                            border: OutlineInputBorder()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Şifre',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  final err = await Cloud.instance
                                      .saveConfig(
                                          _url.text, _key.text);
                                  if (!mounted) return;
                                  if (err != null) {
                                    _msg(err, err: true);
                                    return;
                                  }
                                  await Cloud.instance
                                      .setDeviceCode(_device.text
                                          .trim()
                                          .isEmpty
                                          ? 'K1'
                                          : _device.text
                                              .trim()
                                              .toUpperCase());
                                  _msg(
                                      'Kaydedildi. Uygulamayı kapatıp açın.');
                                } finally {
                                  if (mounted) {
                                    setState(
                                        () => _busy = false);
                                  }
                                }
                              },
                        icon: const Icon(Icons.save),
                        label: const Text('Kaydet'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  final err =
                                      await Cloud.instance.signIn(
                                          _email.text,
                                          _pass.text);
                                  if (!mounted) return;
                                  if (err == null) {
                                    _msg(
                                        'Bağlandı: ${Cloud.instance.userEmail ?? ''}');
                                  } else {
                                    _msg('Giriş hatası: $err',
                                        err: true);
                                  }
                                } finally {
                                  if (mounted) {
                                    setState(
                                        () => _busy = false);
                                  }
                                }
                              },
                        icon: const Icon(Icons.login),
                        label: const Text('Bağlan'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () =>
                        Cloud.instance.syncNow(),
                    icon: const Icon(Icons.sync),
                    label:
                        const Text('Şimdi Senkronize Et'),
                  ),
                ),
                if (Cloud.instance.isAuthed)
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Cloud.instance.signOut();
                        _msg('Çıkış yapıldı.');
                      },
                      icon: const Icon(Icons.logout,
                          color: Colors.red),
                      label: Text(
                        'Çıkış Yap (${Cloud.instance.userEmail ?? ''})',
                        style: const TextStyle(
                            color: Colors.red),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Senkron tanı kartı: yerel vs bulut sayaçları yan yana.
/// Bozuk taraf tek bakışta belli olur.
class DiagCard extends StatefulWidget {
  const DiagCard({super.key});

  @override
  State<DiagCard> createState() => _DiagCardState();
}

class _DiagCardState extends State<DiagCard> {
  Map<String, String>? _info;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final info = await Cloud.instance.debugInfo();
      if (mounted) setState(() => _info = info);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.medical_services),
        title: const Text('Senkron Tanı'),
        subtitle: const Text('Yerel vs bulut sayaçları'),
        children: [
          if (_busy && _info == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_info != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  _row('Cihaz', _info!['cihaz'] ?? '?'),
                  _row('E-posta', _info!['eposta'] ?? '-'),
                  const Divider(),
                  _row('Yerel ürün', _info!['yerel_urun'] ?? '?',
                      alt: 'Bulut ürün: ${_info!['bulut_urun'] ?? '?'}'),
                  _row('Yerel satış', _info!['yerel_satis'] ?? '?',
                      alt: 'Bulut satış: ${_info!['bulut_satis'] ?? '?'}'),
                  _row('Yerel hareket',
                      _info!['yerel_hareket'] ?? '?',
                      alt:
                          'Bulut hareket: ${_info!['bulut_hareket'] ?? '?'}'),
                  const Divider(),
                  _row('Kuyruk', _info!['kuyruk'] ?? '?'),
                  _row('Son çekiş', _info!['son_cekis'] ?? '-'),
                  if (_info!.containsKey('push_hata'))
                    _row('Push hatası', _info!['push_hata']!,
                        err: true),
                  if (_info!.containsKey('bulut_hata'))
                    _row('Bulut hatası', _info!['bulut_hata']!,
                        err: true),
                  if (_info!.containsKey('son_hata'))
                    _row('Son hata', _info!['son_hata']!,
                        err: true),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Yenile'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy
                        ? null
                        : () async {
                            final messenger =
                                ScaffoldMessenger.of(context);
                            setState(() => _busy = true);
                            try {
                              final n = await Cloud.instance
                                  .requeueAndSync();
                              messenger.showSnackBar(SnackBar(
                                  content: Text(
                                      '$n satır kuyruğa kuruldu, senkron çalıştı.')));
                            } finally {
                              await _load();
                            }
                          },
                    icon:
                        const Icon(Icons.upload_rounded, size: 18),
                    label: const Text('Tümünü Gönder'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v, {String? alt, bool err = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child: Text(k,
                  style: const TextStyle(color: Colors.grey))),
          if (alt != null)
            Expanded(
                child: Text(alt,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.grey))),
          Expanded(
            child: Text(v,
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: err ? Colors.red : null)),
          ),
        ],
      ),
    );
  }
}
