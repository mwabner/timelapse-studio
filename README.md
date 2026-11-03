# Timelapse Studio

macOS-App zur Bearbeitung von Zeitraffersequenzen, entwickelt mit Swift und Xcode.

## Status

Dieses Repository wird für die Veröffentlichung vorbereitet. Der aktuelle Xcode-Projektstand ist noch nicht hochgeladen. Es gibt noch keine herunterladbare App-Version und keine hier geprüfte Build-Anleitung.

## Bisheriger Entwicklungsstand

Im bisherigen lokalen Projekt wurden Bildimport, Belichtungs-Keyframes, Deflicker, JSON-Projektdateien und MP4-Export umgesetzt. RAW- und Hintergrundimport wurden anschließend ergänzt. Diese Funktionen müssen nach Übernahme des aktuellen Quellcodes im Repository überprüft werden.

## Nächste Schritte

- Aktuelles Xcode-Projekt übernehmen und persönliche Einstellungen sowie Zugangsdaten ausschließen.
- Voraussetzungen, unterstützte macOS-Version und Build-Schritte am tatsächlichen Projekt prüfen und dokumentieren.
- Funktionen testen und Screenshots ergänzen.
- Lizenzentscheidung vor der Freigabe zur Weiterverwendung treffen.
- Erste macOS-Version als GitHub Release vorbereiten; Signierung und Notarisierung prüfen.

## Entwicklung

Die `.gitignore` schließt lokale Xcode-Builds, Benutzereinstellungen und übliche Signierungsdateien aus. Eigene Fotoserien und Exporte gehören nicht in die Versionsverwaltung; dafür sind die ignorierten Ordner `local-media/` und `exports/` vorgesehen.
