import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // tr_TR tarih formatı (fday/fdate) için şart — yoksa Özet/Rapor çöker.
  await initializeDateFormatting('tr_TR');
  runApp(const ProviderScope(child: KirtasiyeApp()));
}
