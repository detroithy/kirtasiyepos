import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/database/app_db.dart';
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
    // İlk açılış örnek verisi (tek seferlik, tablo boşsa).
    Future.microtask(() async {
      await ref.read(dbProvider).ensureSeed();
      if (mounted) setState(() => _seeded = true);
    });
  }

  static const _pages = [
    PosScreen(),
    ProductsScreen(),
    StockScreen(),
    DashboardScreen(),
    ReportsScreen(),
    SettingsScreen(),
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
      bottomNavigationBar: NavigationBar(
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
    );
  }
}
