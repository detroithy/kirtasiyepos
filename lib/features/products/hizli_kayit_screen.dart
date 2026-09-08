import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/utils/money.dart';
import '../sales/scan_screen.dart';
import 'quick_add.dart';

/// Hızlı Kayıt: okuyucuyla raf gezme modu.
/// Tara → varsa göster, yoksa hızlı form → sıradakine geç.
/// USB okuyucu Enter bastığı için el değmeden akar.
class HizliKayitScreen extends ConsumerStatefulWidget {
  const HizliKayitScreen({super.key});

  @override
  ConsumerState<HizliKayitScreen> createState() =>
      _HizliKayitScreenState();
}

class _SessionEntry {
  final String barcode;
  final String name;
  final bool isNew; // true=eklendi, false=zaten vardı
  _SessionEntry(this.barcode, this.name, this.isNew);
}

class _HizliKayitScreenState
    extends ConsumerState<HizliKayitScreen> {
  final _codeCtrl = TextEditingController();
  final _focus = FocusNode();
  final List<_SessionEntry> _session = [];
  Product? _lastFound;
  bool _busy = false;

  AppDb get _db => ref.read(dbProvider);

  int get _added =>
      _session.where((e) => e.isNew).length;

  void _refocus() {
    if (mounted) _focus.requestFocus();
  }

  Future<void> _onCode(String raw) async {
    final code = raw.trim();
    if (code.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _lastFound = null;
    });
    try {
      final p = await _db.findByBarcode(code);
      if (!mounted) return;
      if (p != null) {
        setState(() {
          _lastFound = p;
          _session.insert(0, _SessionEntry(code, p.name, false));
        });
      } else {
        final created =
            await showQuickAddSheet(context, _db, code);
        if (!mounted) return;
        if (created != null) {
          setState(() {
            _session.insert(
                0, _SessionEntry(code, created.name, true));
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Eklendi: ${created.name}'),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 1),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _codeCtrl.clear();
      _refocus();
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canScan = Platform.isAndroid || Platform.isIOS;
    return Scaffold(
      appBar: AppBar(
        title: const Text('KırtasiyePOS • Hızlı Kayıt'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text('$_added eklendi',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _codeCtrl,
              focusNode: _focus,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Barkodu okut veya yaz + Enter',
                prefixIcon: const Icon(Icons.qr_code_scanner),
                suffixIcon: canScan
                    ? IconButton(
                        icon:
                            const Icon(Icons.photo_camera),
                        onPressed: () async {
                          final code =
                              await Navigator.push<String>(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const ScanScreen()),
                          );
                          if (code != null &&
                              code.isNotEmpty) {
                            await _onCode(code);
                          }
                          _refocus();
                        },
                      )
                    : null,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: _onCode,
              textInputAction: TextInputAction.go,
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_lastFound != null)
            Card(
              margin: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 4),
              color: Colors.blue.shade50,
              child: ListTile(
                leading: const Icon(Icons.check_circle,
                    color: Colors.blue),
                title: Text(_lastFound!.name),
                subtitle: Text(
                    '${money(_lastFound!.sellPrice)} • Stok: ${fmtQty(_lastFound!.stock)}'),
                trailing: const Text('Kayıtlı',
                    style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Text('Bu oturum (${_session.length})',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall),
                const Spacer(),
                if (_session.isNotEmpty)
                  TextButton(
                    onPressed: () =>
                        setState(() => _session.clear()),
                    child: const Text('Temizle'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _session.isEmpty
                ? const Center(
                    child: Text(
                        'Okutmaya başla — her taramada odak buraya döner.'))
                : ListView.builder(
                    itemCount: _session.length,
                    itemBuilder: (_, i) {
                      final e = _session[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          e.isNew
                              ? Icons.add_circle
                              : Icons.check_circle_outline,
                          color: e.isNew
                              ? Colors.green
                              : Colors.blue,
                        ),
                        title: Text(e.name),
                        subtitle: Text(e.barcode),
                        trailing: Text(
                          e.isNew ? 'Eklendi' : 'Kayıtlı',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: e.isNew
                                ? Colors.green.shade700
                                : Colors.blue,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
