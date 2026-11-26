import 'package:flutter/foundation.dart';

/// Plattform-Abfragen, die auch im Browser funktionieren (ohne dart:io).
bool get isWeb => kIsWeb;
bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);
bool get isMobile =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// Dateien vom Gerät lesen/speichern (nicht im Browser).
bool get hasFileSystem => !kIsWeb;
