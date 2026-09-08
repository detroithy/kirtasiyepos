import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

/// Mobil kamera ile barkod okutma. Bulunan kod pop ile döner.
/// Sadece Android/iOS'ta açılır (Windows'ta USB okuyucu kullanılır).
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _denied = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _askPermission();
  }

  Future<void> _askPermission() async {
    final s = await Permission.camera.request();
    if (!mounted) return;
    setState(() => _denied = !s.isGranted);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Barkod Okut')),
      body: _denied
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Kamera izni verilmedi.'),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: openAppSettings,
                    child: const Text('Ayarları Aç'),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: (capture) {
                    if (_done) return;
                    final code = capture.barcodes
                        .map((b) => b.rawValue)
                        .firstWhere((v) => v != null && v.isNotEmpty,
                            orElse: () => null);
                    if (code != null) {
                      _done = true;
                      Navigator.pop(context, code);
                    }
                  },
                ),
                // Hedef çerçeve
                Center(
                  child: Container(
                    width: 260,
                    height: 160,
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: Colors.amber, width: 3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Barkodu çerçevenin içine getirin',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
