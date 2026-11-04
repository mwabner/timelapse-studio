# Erste macOS-Veröffentlichung vorbereiten

Der Quellcode ist öffentlich verfügbar. Ein herunterladbares App-Release ist noch nicht freigegeben.

1. Debug- und Release-Build auf einem Mac erfolgreich prüfen; `TESTPLAN.md` abarbeiten.
2. App-Name, Icon und Bundle-ID `com.mwabner.timelapsestudio` überprüfen. Diese Bundle-ID ist eine Projektvorgabe, keine bestätigte Apple-Registrierung. Vor dem ersten signierten Release endgültig festlegen.
3. Lizenz und Rechte am veröffentlichten Material festlegen.
4. Unterstützte macOS-Version und Prozessorarchitekturen durch reale Builds/Tests bestätigen. Vor einem Universal-Build beide Architekturen prüfen.
5. In Xcode das eigene Signing Team setzen; passende Developer-ID-Zertifikate für die Verteilung außerhalb des App Store verwenden. Keine Schlüssel, Zertifikate oder Notarisierungs-Zugangsdaten committen.
6. Mit dem gemeinsamen Schema TimeLaps einen Release-Archive erstellen. App signieren, Apples Notarisierung erfolgreich durchlaufen und das Ticket anheften. Signierung, Gatekeeper und Start auf einem weiteren Mac prüfen.
7. App als ZIP oder DMG verpacken; Versionsnummer, SHA-256-Prüfsumme, Voraussetzungen, bekannte Einschränkungen und Testergebnisse dokumentieren.
8. Erst danach ein GitHub Release mit passendem Versions-Tag und App-Download erstellen.

Build ohne Signierung ist für Entwicklungsprüfungen vorgesehen. Er ersetzt weder Signierung noch Notarisierung oder die Tests für ein verteilbares Release.
