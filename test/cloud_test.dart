import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/sync/cloud.dart';

void main() {
  test('geçerli Supabase URL normalize edilir', () {
    expect(
        Cloud.normalizeSupabaseUrl('https://xyz.supabase.co'),
        'https://xyz.supabase.co');
    expect(
        Cloud.normalizeSupabaseUrl('  https://xyz.supabase.co/  '),
        'https://xyz.supabase.co');
    expect(
        Cloud.normalizeSupabaseUrl('Https://Xyz.Supabase.Co'),
        'https://xyz.supabase.co');
  });

  test('bozuk URL reddedilir', () {
    expect(
        Cloud.normalizeSupabaseUrl(
            'https://supabase.com/dashboard/project/xyz'),
        isNull);
    expect(
        Cloud.normalizeSupabaseUrl('https://xyz.supabase.co/auth/v1'),
        isNull);
    expect(Cloud.normalizeSupabaseUrl('xyz.supabase.co'), isNull);
    expect(Cloud.normalizeSupabaseUrl(''), isNull);
  });

  test('push sırası üst satırları öne alır', () {
    expect(pushRank('categories'), lessThan(pushRank('products')));
    expect(pushRank('products'), lessThan(pushRank('sales')));
    expect(pushRank('sales'), lessThan(pushRank('sale_items')));
    expect(pushRank('sales'), lessThan(pushRank('stock_movements')));
    final order = [
      'sale_items',
      'sales',
      'products',
      'categories',
      'stock_movements',
      'expenses',
    ]..sort((a, b) {
        final r = pushRank(a).compareTo(pushRank(b));
        return r != 0 ? r : a.compareTo(b);
      });
    expect(order.indexOf('categories'), lessThan(order.indexOf('products')));
    expect(order.indexOf('products'), lessThan(order.indexOf('sales')));
  });
}
