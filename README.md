# Fachinformatiker Prüfungs-Runner (AP1 / AP2)

Lizenz: AGPL-3.0 (siehe `LICENSE` und `NOTICE.md`).

**Spielen:**
- **Browser (PC und Handy):** https://fachinformatiker-lernspiel.netlify.app (auf dem Handy: „Zum Startbildschirm hinzufügen“)
- **Downloads** für Windows, Mac, Linux und Android: https://github.com/karoll187871-crypto/fachinformatiker-lernspiel/releases/latest

Ein **Konto** (im Spiel oben rechts) speichert deinen Spielstand online. Mit derselben E-Mail spielst du auf jedem Gerät weiter.

## Neu in Version 2.2

- Web-Version und Hochkant-Layout fürs Handy (Wischen und Tippen)
- Konto-System mit Cloud-Spielstand (Netlify Identity + Netlify Blobs, Funktion `netlify/functions/save.mts`)
- Builds für Linux (AppImage), macOS, Android (APK) und Windows über GitHub Actions (`.github/workflows/build.yml`). Ein Tag `v*` erzeugt ein Release.
- Zeitlupe bei Fragen, Abschlusstest, Himmel-Shop, YouTube in „Meine Musik“ (nur Windows)

## Neu in Version 2.1

- **Performance:** Die ganze 3D-Welt wird mit einem einzigen GPU-Aufruf pro Bild gezeichnet (`drawVertices`). Das HUD wird gedrosselt neu aufgebaut. Grafik „Auto“ misst die Bildrate und senkt bei Ruckeln die Qualität (Einstellungen → Grafik).
- **Rollen:** Die Figur rollt sich jetzt als Kugel zusammen und überschlägt sich, mit Staubwolke.
- **Musik & Sound:** Spielmusik und Effekte werden beim Start synthetisch erzeugt, daher gibt es keine großen Audiodateien. Musik lässt sich stummschalten (Noten-Knopf), eigene Musikdateien sind möglich, YouTube-Links öffnen sich im Browser.
- **Power-ups:** Münzmagnet, Schutzschild, 2× Punkte, Super-Sprung (über Züge).
- **XP, Level & Kapitel:** XP für richtige Antworten; eine kleine Story mit 8 Kapiteln.
- **Tagesquests** mit Prüfungsbezug (z. B. „3× richtig im Thema Netzwerk“).
- **Shop:** Skins (u. a. Tarnmuster), Laufspuren und Wissens-Kisten mit seltenen Belohnungen.
- **Lernkarten (cwillam, AGPL-3.0):** 2.965 Karten aus AP1, AP2 FIAE und AP2 FISI. 2.694 davon laufen als 3-Antworten-Fragen im Lauf mit (im Menü abschaltbar, AP2-Fachrichtung wählbar). Alle Karten gibt es im neuen Lernkarten-Modus mit Karteikasten-System. Import: `python tool/cwillam_import.py <ordner>`, Details in `NOTICE.md`.
- **Fragen:** 401 eingebaute Fragen. Eigene Fragen lassen sich als JSON importieren (Einstellungen → Eigene Fragen).

## Steuerung

| Taste | Aktion |
|---|---|
| A / D oder ← / → | Spur wechseln |
| W / ↑ / Leertaste | Springen |
| S / ↓ | Rollen / Ducken (endet automatisch, Sprung bricht es ab) |
| P / Esc | Pause |
| F11 oder Alt+Enter | Vollbild an/aus |
| Enter | Starten / Weiter |

## Spielregeln

- 3 Leben. Falsche Antwort = −1 Leben + Erklärung. Die Frage kommt kurz danach erneut.
- 3 richtige Antworten in Folge = +1 Leben (max. 5). Serie erhöht den Punkte-Multiplikator.
- Tempo **Entspannt**: Unfälle kosten kein Leben, nur falsche Antworten.
- Fragen, die du oft falsch hast, kommen häufiger dran. Fortschritt wird lokal gespeichert.

## Fragen bearbeiten

Neue Fragen kannst du in `tool/neue_fragen.py` ergänzen. Danach `python tool/neue_fragen.py` ausführen. Das Skript prüft doppelte und zu lange Antworten (max. 44 Zeichen, damit sie auf die Tore passen) und sortiert die Fragen in `fragen.json` ein.


Alle Fragen stehen in `assets/questions/fragen.json`:

```json
{"pruefung":"AP1","thema":"Netzwerk","frage":"…","richtig":"…","falsch":["…","…","…"],"erklaerung":"…"}
```

Antworten kurz halten (max. ca. 40 Zeichen), damit sie auf die Tore passen.
`flutter test` prüft den Katalog auf Fehler.

## Eine exe zum Weitergeben

```
powershell -ExecutionPolicy Bypass -File tool\package.ps1
```

Das ergibt `dist\Fachinformatiker-Lernspiel.exe` (ca. 14 MB), gepackt mit dem in Windows eingebauten IExpress. Ein Doppelklick installiert das Spiel ohne Admin-Rechte nach `%LOCALAPPDATA%\Programs\FachinformatikerLernspiel`. Dabei entstehen eine Desktop-Verknüpfung und ein Eintrag zum Entfernen im Startmenü, und das Spiel startet. Ein Spielstand ist nicht enthalten, jeder startet bei Null. Die VC++-Laufzeit und `Quellcode.zip` (AGPL) sind dabei.

## Bauen

```powershell
flutter build windows
```

Die EXE liegt danach in `build\windows\x64\runner\Release\`.

## Projektstruktur

```
lib/
├── main.dart                # Start, F11-Vollbild
├── ui.dart                  # Farben, Skalierung, Fenstersteuerung
├── data/question_bank.dart  # Fragen laden, Fragen-Deck (Wiederholung)
├── data/progress.dart       # Highscore, Statistik (shared_preferences)
├── game/engine.dart         # Spiellogik, Physik, Kollision, Tore
├── game/renderer.dart       # 3D-Perspektivprojektion auf Canvas
└── screens/                 # Menü, Spiel + HUD, Fragenkatalog
windows/runner/              # Vollbild-Kanal "lernspiel/window"
```

Die alte Version liegt unverändert in `_backup_alte_version_2026-11-25/`.
