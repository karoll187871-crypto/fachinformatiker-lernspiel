import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color kAccent = Color(0xFF4FC3F7);
const Color kGood = Color(0xFF00E676);
const Color kBad = Color(0xFFFF5252);
const Color kGold = Color(0xFFFFD54F);
const Color kPanel = Color(0xE0141826);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFF0D1020),
    fontFamily: 'Segoe UI',
  );
}

/// Skalierungsfaktor relativ zu 1280×720, damit die Oberfläche
/// in jedem Fenster und im Vollbild gleich aussieht.
double uiScale(Size size) => isPortrait(size)
    ? (size.width / 480).clamp(0.6, 1.4)
    : min(size.width / 1280, size.height / 720).clamp(0.7, 2.4);

/// Hochkant (Handy)?
bool isPortrait(Size size) => size.height > size.width * 1.1;

/// Fenstersteuerung über den nativen Windows-Runner.
class AppWindow {
  static const _channel = MethodChannel('lernspiel/window');

  static Future<void> toggleFullscreen() async {
    try {
      await _channel.invokeMethod<bool>('toggleFullscreen');
    } catch (_) {
      // Auf anderen Plattformen nicht verfügbar.
    }
  }

  static Future<void> quit() async {
    try {
      await _channel.invokeMethod<void>('quit');
    } catch (_) {
      await SystemNavigator.pop();
    }
  }
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding,
    this.color = kPanel,
    this.border,
    this.radius = 18,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color color;
  final Color? border;
  final double radius;
  final bool shadow; // weicher Schatten kostet Leistung, im Spiel aus

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
            color: border ?? Colors.white.withValues(alpha: 0.10), width: 1.5),
        boxShadow: shadow
            ? const [
                BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
              ]
            : null,
      ),
      child: child,
    );
  }
}

class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key, this.size = 14});
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: EdgeInsets.symmetric(horizontal: size * 0.5, vertical: size * 0.15),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.35),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: size, fontWeight: FontWeight.w700, color: Colors.white)),
    );
  }
}

class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = kAccent,
    this.scale = 1,
    this.hint,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final Color color;
  final double scale;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.black,
        padding: EdgeInsets.symmetric(horizontal: 22 * scale, vertical: 14 * scale),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14 * scale)),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 22 * scale),
            SizedBox(width: 8 * scale),
          ],
          Text(label,
              style: TextStyle(fontSize: 17 * scale, fontWeight: FontWeight.w800)),
          if (hint != null) ...[
            SizedBox(width: 10 * scale),
            Text(hint!,
                style: TextStyle(
                    fontSize: 12 * scale,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withValues(alpha: 0.55))),
          ],
        ],
      ),
    );
  }
}
