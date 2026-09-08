import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Yedekleme + donanım durumu + bilgi ekranı.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('KırtasiyePOS • Ayarlar')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
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
