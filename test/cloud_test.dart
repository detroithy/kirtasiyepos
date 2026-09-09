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
}
