import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_hub.dart';

/// Yönetici PIN kapısı. Varsayılan PIN: 1234 (hub içinden değiştirilir).
Future<void> openAdmin(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final pin = prefs.getString('admin_pin') ?? '1234';
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinDialog(correctPin: pin),
  );
  if (ok == true && context.mounted) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AdminHub()),
    );
  }
}

class _PinDialog extends StatefulWidget {
  final String correctPin;
  const _PinDialog({required this.correctPin});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  String _entered = '';
  String? _error;

  void _press(String d) {
    if (_entered.length >= 6) return;
    setState(() {
      _entered += d;
      _error = null;
    });
    if (_entered.length == widget.correctPin.length) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        if (_entered == widget.correctPin) {
          Navigator.pop(context, true);
        } else {
          setState(() {
            _error = 'Hatalı PIN';
            _entered = '';
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Yönetim Paneli'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Yönetici PIN’ini girin',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.correctPin.length,
              (i) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _entered.length
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade300,
                ),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 8),
          const Text('Varsayılan: 1234',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
                _key(d),
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Vazgeç')),
              _key('0'),
              IconButton(
                icon: const Icon(Icons.backspace_outlined),
                onPressed: () => setState(() {
                  if (_entered.isNotEmpty) {
                    _entered =
                        _entered.substring(0, _entered.length - 1);
                  }
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _key(String d) {
    return FilledButton.tonal(
      onPressed: () => _press(d),
      child: Text(d, style: const TextStyle(fontSize: 20)),
    );
  }
}

/// Hub içinden PIN değiştirme.
Future<void> changeAdminPin(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final p1 = TextEditingController();
  final p2 = TextEditingController();
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('PIN Değiştir'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: p1,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(
                labelText: 'Yeni PIN (4-6 hane)',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: p2,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(
                labelText: 'Yeni PIN (tekrar)',
                border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Vazgeç')),
        FilledButton(
          onPressed: () async {
            if (p1.text.length < 4 || p1.text != p2.text) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                  content: Text(
                      'PIN en az 4 hane ve iki girişte aynı olmalı.')));
              return;
            }
            await prefs.setString('admin_pin', p1.text);
            if (ctx.mounted) Navigator.pop(ctx);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('PIN güncellendi.')));
            }
          },
          child: const Text('Kaydet'),
        ),
      ],
    ),
  );
}
