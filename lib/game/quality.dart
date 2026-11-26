import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'renderer.dart';

/// Misst die echten Frame-Zeiten und senkt bei "Auto" die Grafikqualität,
/// wenn der Rechner nicht hinterherkommt. So läuft das Spiel auf
/// schwachen Laptops flüssig und sieht auf starken PCs gut aus.
class QualityGovernor {
  QualityGovernor._();
  static final QualityGovernor instance = QualityGovernor._();

  String mode = 'auto';
  final ValueNotifier<double> fps = ValueNotifier(0);
  bool _listening = false;
  final List<int> _recent = [];
  int _slowWindows = 0;
  int _fastWindows = 0;

  void setMode(String m) {
    mode = m;
    switch (m) {
      case 'high':
        RenderSettings.level = 2;
      case 'mid':
        RenderSettings.level = 1;
      case 'low':
        RenderSettings.level = 0;
      default:
        RenderSettings.level = 2;
        _slowWindows = 0;
        _fastWindows = 0;
    }
  }

  void start() {
    if (_listening) return;
    _listening = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      // längere der beiden Phasen bestimmt die Bildrate
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      _recent.add(build > raster ? build : raster);
    }
    if (_recent.length < 60) return;
    var sum = 0;
    for (final v in _recent) {
      sum += v;
    }
    final avg = sum / _recent.length;
    _recent.clear();
    fps.value = avg <= 0 ? 0 : (1e6 / avg).clamp(0, 999).toDouble();
    if (mode != 'auto') return;
    if (avg > 15500) {
      // unter ~60 FPS möglich: eine Stufe runter
      _slowWindows++;
      _fastWindows = 0;
      if (_slowWindows >= 2 && RenderSettings.level > 0) {
        RenderSettings.level--;
        _slowWindows = 0;
      }
    } else if (avg < 6000) {
      _fastWindows++;
      _slowWindows = 0;
      if (_fastWindows >= 20 && RenderSettings.level < 2) {
        RenderSettings.level++;
        _fastWindows = 0;
      }
    } else {
      _slowWindows = 0;
    }
  }
}
