import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/database/app_db.dart';
import 'core/sync/cloud.dart';
import 'core/theme/app_theme.dart';
import 'features/accounting/dashboard_screen.dart';
import 'features/products/products_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/sales/pos_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/stock/stock_screen.dart';

/// Tek DB instance'ı tüm uygulamada paylaşılır.
final dbProvider = Provider<AppDb>((ref) {
  final db = AppDb();
  ref.onDispose(() => db.close());
  return db;
});

class KirtasiyeApp extends StatelessWidget {
  const KirtasiyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KırtasiyePOS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    // İlk açılış örnek verisi (tek seferlik, tablo boşsa) + bulut.
    Future.microtask(() async {
      final db = ref.read(dbProvider);
      await db.ensureSeed();
      await Cloud.instance.init(db);
      if (mounted) setState(() => _seeded = true);
    });
  }

  /// Görünür sekme active=true alır -> FutureBuilder'lı ekranlar
  /// sekmeye dönünce veriyi tazeler (POS sepeti gibi state'ler korunur:
  /// const sayfalar aynı instance ile yaşar).
  List<Widget> get _pages => [
        const PosScreen(),
        const ProductsScreen(),
        StockScreen(active: _index == 2),
        DashboardScreen(active: _index == 3),
        ReportsScreen(active: _index == 4),
        const SettingsScreen(),
      ];

  @override
  Widget build(BuildContext context) {
    if (!_seeded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CloudStrip(),
          NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.point_of_sale), label: 'Satış'),
          NavigationDestination(
              icon: Icon(Icons.inventory_2), label: 'Ürünler'),
          NavigationDestination(icon: Icon(Icons.warehouse), label: 'Stok'),
          NavigationDestination(
              icon: Icon(Icons.dashboard), label: 'Özet'),
          NavigationDestination(
              icon: Icon(Icons.bar_chart), label: 'Rapor'),
          NavigationDestination(
              icon: Icon(Icons.settings), label: 'Ayarlar'),
        ],
          ),
        ],
      ),
    );
  }
}

/// Alt barda ince bulut şeridi: bağlantı + bekleyen işlem.
class CloudStrip extends StatelessWidget {
  const CloudStrip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CloudStatus>(
      valueListenable: cloudStatus,
      builder: (_, s, child) {
        late Color bg;
        late String text;
        switch (s.mode) {
          case CloudMode.off:
            return const SizedBox.shrink();
          case CloudMode.online:
            bg = PosColors.okBg;
            text = s.pending > 0
                ? '🟢 Çevrimiçi • ${s.pending} işlem bekliyor'
                : '🟢 Çevrimiçi • Senkron';
            break;
          case CloudMode.offline:
            bg = PosColors.warnBg;
            text =
                '🟠 Çevrimdışı • ${s.pending} işlem kuyrukta';
            break;
          case CloudMode.syncing:
            bg = PosColors.infoBg;
            text = '🔄 Senkronize ediliyor...';
            break;
          case CloudMode.error:
            bg = PosColors.critBg;
            text = '🔴 Senkron hatası • ${s.pending} bekliyor';
            break;
        }
        return InkWell(
          onTap: () => Cloud.instance.syncNow(),
          child: Container(
            width: double.infinity,
            color: bg,
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11)),
          ),
        );
      },
    );
  }
}
