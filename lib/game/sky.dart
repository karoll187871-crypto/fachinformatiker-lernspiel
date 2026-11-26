import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/cosmetics.dart';
import '../data/progress.dart';
import '../platform.dart';

/// Aktueller Himmel für den Renderer (gekaufte Farbe oder eigenes Bild).
class SkyStore {
  static SkyTheme theme = kSkies.first;
  static ui.Image? image;
  static int fog = kSkies.first.fog;

  /// Gewählten Himmel aus dem Spielstand laden.
  static Future<void> apply(Progress p) async {
    final t = skyById(p.skyId);
    if (t.custom) {
      final path = p.customSkyPath;
      if (hasFileSystem && path != null && await _loadImage(path)) {
        theme = t;
        return;
      }
      theme = kSkies.first; // Bild fehlt: Standardhimmel
      fog = theme.fog;
      return;
    }
    theme = t;
    fog = t.fog;
  }

  /// Bild in den App-Datenordner kopieren (damit es nicht verloren geht,
  /// wenn das Original verschoben wird) und laden.
  static Future<String?> importImage(String source) async {
    try {
      final base = (await getApplicationSupportDirectory()).path;
      final dir = Directory('$base${Platform.pathSeparator}himmel');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = source.split('.').last.toLowerCase();
      final target =
          '${dir.path}${Platform.pathSeparator}himmel_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await File(source).copy(target);
      if (!await _loadImage(target)) return null;
      // alte Kopien aufräumen
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path != target && f.path.contains('himmel_')) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
      return target;
    } catch (e) {
      debugPrint('Himmelsbild: $e');
      return null;
    }
  }

  static Future<bool> _loadImage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      // Auf max. 1920 px Breite verkleinern: spart Speicher und Rechenzeit
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1920, allowUpscaling: false);
      final frame = await codec.getNextFrame();
      image?.dispose();
      image = frame.image;
      fog = await _horizonColor(frame.image);
      return true;
    } catch (e) {
      debugPrint('Himmelsbild laden: $e');
      return false;
    }
  }

  /// Mittlere Farbe des unteren Bildrands als Nebelfarbe, damit der
  /// Übergang zum Boden natürlich aussieht.
  static Future<int> _horizonColor(ui.Image img) async {
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return kSkies.first.fog;
    final w = img.width, h = img.height;
    var r = 0, g = 0, b = 0, n = 0;
    final y0 = (h * 0.8).floor();
    for (var y = y0; y < h; y += 2) {
      for (var x = 0; x < w; x += 4) {
        final i = (y * w + x) * 4;
        r += data.getUint8(i);
        g += data.getUint8(i + 1);
        b += data.getUint8(i + 2);
        n++;
      }
    }
    if (n == 0) return kSkies.first.fog;
    // etwas abdunkeln, damit die Szene lesbar bleibt
    int c(int v) => ((v / n) * 0.8).round().clamp(0, 255);
    return 0xFF000000 | (c(r) << 16) | (c(g) << 8) | c(b);
  }
}
