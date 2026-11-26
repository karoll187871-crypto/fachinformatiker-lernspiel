#!/usr/bin/env bash
# Baut die Linux-Version und packt sie in EINE Datei (AppImage).
# Läuft unter Ubuntu/WSL. Aufruf aus Windows:
#   wsl -d Ubuntu -- bash /mnt/c/<Pfad-zum-Projekt>/tool/build_linux.sh
# Ergebnis: dist/Fachinformatiker-Lernspiel-x86_64.AppImage  (+ .tar.gz als Ersatz)
#
# Kein Spielstand wird mitgepackt: Spielstände liegen unter Linux pro Benutzer in
# ~/.local/share/com.example.fachinformatiker_lernspiel/ und entstehen erst beim Spielen.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$HOME/lernspiel-build"
FLUTTER_DIR="$HOME/flutter"
FLUTTER_VERSION="3.50.1"
OUT="$SRC/dist"

echo "==> Pakete installieren (einmalig, fragt nach dem Linux-Passwort)"
sudo apt-get update -y
sudo apt-get install -y curl git unzip xz-utils zip file clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-base gstreamer1.0-libav

if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  echo "==> Flutter $FLUTTER_VERSION für Linux laden"
  curl -fL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    -o /tmp/flutter.tar.xz
  tar -xf /tmp/flutter.tar.xz -C "$HOME"
  rm /tmp/flutter.tar.xz
fi
export PATH="$FLUTTER_DIR/bin:$PATH"
git config --global --add safe.directory "$FLUTTER_DIR" || true
flutter config --no-analytics --enable-linux-desktop >/dev/null

echo "==> Quellcode in ein Linux-Verzeichnis kopieren (schneller als /mnt/c)"
rm -rf "$WORK"
mkdir -p "$WORK"
for item in lib assets linux test tool pubspec.yaml pubspec.lock analysis_options.yaml README.md LICENSE NOTICE.md; do
  cp -r "$SRC/$item" "$WORK/"
done
cd "$WORK"
flutter pub get
flutter test
flutter build linux --release

BUNDLE="$WORK/build/linux/x64/release/bundle"
mkdir -p "$OUT"

echo "==> AppImage bauen"
APPDIR="$WORK/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
cp -r "$BUNDLE"/. "$APPDIR/usr/bin/"
cp LICENSE "$APPDIR/usr/bin/LICENSE.txt"
cp NOTICE.md "$APPDIR/usr/bin/NOTICE.md"
# Quellcode mitgeben (AGPL-3.0)
(cd "$WORK" && zip -qr "$APPDIR/usr/bin/Quellcode.zip" lib assets linux test tool pubspec.yaml pubspec.lock \
  analysis_options.yaml README.md LICENSE NOTICE.md -x 'linux/flutter/ephemeral/*')

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
cd "$HERE/usr/bin"
exec "$HERE/usr/bin/fachinformatiker_lernspiel" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/fachinformatiker-lernspiel.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fachinformatiker Lernspiel
Comment=AP1/AP2-Prüfungs-Runner
Exec=fachinformatiker_lernspiel
Icon=fachinformatiker-lernspiel
Categories=Education;Game;
Terminal=false
EOF

# Symbol: aus dem Windows-Icon, sonst einfaches Ersatzbild
ICON_SRC="$SRC/windows/runner/resources/app_icon.ico"
if command -v convert >/dev/null 2>&1 && [ -f "$ICON_SRC" ]; then
  convert "$ICON_SRC[0]" "$APPDIR/fachinformatiker-lernspiel.png" || true
fi
if [ ! -f "$APPDIR/fachinformatiker-lernspiel.png" ]; then
  # 1x1-PNG als Platzhalter (AppImage verlangt ein Icon)
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\x8f\xa7\x1e\x00\x04\xc5\x01\xf4\xa8\xa4\x8b\xe5\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$APPDIR/fachinformatiker-lernspiel.png"
fi

TOOL="$HOME/appimagetool-x86_64.AppImage"
if [ ! -x "$TOOL" ]; then
  curl -fL "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" -o "$TOOL"
  chmod +x "$TOOL"
fi
APPIMAGE="$OUT/Fachinformatiker-Lernspiel-x86_64.AppImage"
rm -f "$APPIMAGE"
# --appimage-extract-and-run: funktioniert auch ohne FUSE (z. B. in WSL)
ARCH=x86_64 "$TOOL" --appimage-extract-and-run --comp zstd "$APPDIR" "$APPIMAGE"
chmod +x "$APPIMAGE"

echo "==> Ersatz: tar.gz"
tar -C "$APPDIR/usr" -czf "$OUT/Fachinformatiker-Lernspiel-linux-x64.tar.gz" --transform 's,^bin,Fachinformatiker-Lernspiel,' bin

ls -lh "$OUT"
echo "Fertig."
