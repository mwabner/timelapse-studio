# Timelapse Studio

Native macOS-App zum Bearbeiten und Exportieren von Zeitraffersequenzen. SwiftUI-Oberfläche, lokale Bildverarbeitung mit Core Image und H.264-Export mit AVFoundation. Keine externen Pakete, kein Server und kein Konto erforderlich.

## Entwicklungsstand

Version **0.1.0 – Entwicklung**. Der Quellcode aus Michaels bestehendem Xcode-Projekt ist übernommen. Projektkonfiguration, Dokumentation und App-Icon wurden für das Repository vorbereitet. Ein macOS-Build und die Funktionstests dieser überarbeiteten Fassung stehen noch aus. Es gibt noch kein signiertes, notarisiertes App-Release.

## Funktionen im Quellcode

- Import von JPEG, PNG, TIFF, HEIC und durch macOS unterstützten Kamera-RAW-Dateien.
- RAW-Entwicklung mit `CIRAWFilter`, Hintergrundimport mit Fortschritt und Abbruch.
- Filmstreifen, Bildvorschau und Wiedergabe.
- Helligkeitsanalyse, Belichtungs-Keyframes und Interpolation.
- Einfacher Deflicker mit Korrektur bis ungefähr ±1 EV.
- JSON-Projekte mit Dateizugriffsverweisen, Bildrate, Keyframes und Deflicker.
- MP4/H.264-Export in 1920 × 1080 ohne Ton aus den Originaldateien.

## Auf dem Mac starten

1. Xcode 27 verwenden, passend zum ursprünglichen Projekt. Das Projektformat wurde beibehalten. Ältere Xcode-Versionen sind nicht geprüft; die verwendeten Sprachfunktionen benötigen einen aktuellen Swift-Compiler.
2. Terminal öffnen und ausführen:

   ```bash
   mkdir -p ~/Developer
   cd ~/Developer
   git clone https://github.com/mwabner/timelapse-studio.git
   cd timelapse-studio
   open TimeLaps.xcodeproj
   ```

3. In Xcode das Schema **TimeLaps** und das Ziel **My Mac** auswählen.
4. Unter **Signing & Capabilities** bei Bedarf dein eigenes Development Team wählen. Im Repository sind keine Zertifikate und kein Team hinterlegt.
5. Mit **⌘R** bauen und starten.

Das Deployment Target ist auf **macOS 14.0** gesetzt. Das ist eine vorläufige Konfiguration, keine bereits getestete Kompatibilitätszusage. Es wird ausschließlich für macOS gebaut.

Für einen unsignierten Build zur Fehlerprüfung:

```bash
./scripts/check-build.sh
```

Das Skript legt Build-Ausgaben in `build/` ab. Es erzeugt keine für die öffentliche Verteilung geeignete signierte App.

## Benutzung

Bilder importieren, Helligkeitskurve prüfen, Belichtungs-Keyframes setzen und optional Deflicker berechnen. Anschließend ein JSON-Projekt speichern oder ein MP4 exportieren. Die Originalbilder bleiben notwendig; sie werden nicht in die Projektdatei eingebettet.

RAW-Unterstützung hängt vom Kameramodell, Dateiformat und installierten macOS-Decoder ab. Kein vollständiger RAW-Editor, kein HDR, HEVC, ProRes oder Ton. Vorschau und Export können sich farblich geringfügig unterscheiden. Die Helligkeitsanalyse misst das gesamte Bild. Große Sequenzen benötigen RAM und temporären Speicherplatz. Ein Exportabbruch ist noch nicht vorhanden.

## Projektstruktur

- `TimeLaps.xcodeproj` – macOS-Projekt und gemeinsames Schema.
- `TimeLaps/` – sechs Swift-Dateien, Assets und Sandbox-Berechtigungen.
- `docs/TESTPLAN.md` – manuelle Funktionsprüfung.
- `docs/RELEASE.md` – Schritte bis zur herunterladbaren App.
- `scripts/check-build.sh` – reproduzierbarer lokaler Build-Aufruf.

Eigene Medien und Exporte außerhalb des Repositorys oder in den ignorierten Ordnern `local-media/` und `exports/` ablegen. Die Sandbox erlaubt den Zugriff auf ausgewählte Dateien und speichert dafür Zugriffsverweise.

## Lizenz

Eine Open-Source-Lizenz wurde noch nicht festgelegt. Die öffentliche Sichtbarkeit allein erteilt keine allgemeine Erlaubnis zur Weiterverwendung oder Weiterverteilung. Vor einem App-Release ist die Lizenzentscheidung zu treffen.
