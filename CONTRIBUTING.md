# Entwicklung und Beitraege

## Projektstruktur

- `AFM Chat/ChatView.swift`: Chat-Oberfläche, Modellstatus, Upload-Verarbeitung und Foundation-Models-Aufruf.
- `AFM Chat/MCPBridge.swift`: MCP-stdio-Kommunikation, Docker-Prozessstart und Tool-Filter.
- `AFM Chat/AppSettings.swift`: macOS-Einstellungen für temporaeres Verzeichnis und Webdienste.
- `AFM Chat/Assets.xcassets`: App-Icon.
- `docs/`: Setup-, Architektur- und Fehlerbehebungsdokumentation.

## Lokal bauen

Voraussetzungen und Build-Kommandos stehen in der [README](README.md). Das Projekt enthält ein gemeinsames Xcode-Scheme `AFM Chat`.

## Hinweise für Aenderungen

- Halte Chats und Uploads standardmäßig lokal.
- Webzugriffe müssen klar erkennbar und auf die dokumentierten Such- und Leseaktionen begrenzt bleiben.
- Aendere Speicherpfade oder UserDefaults-Schlüssel nicht ohne Migrationspfad; bestehende Installationen verwenden weiterhin `FMChat` als internen Datenbezeichner.
- Aktualisiere `docs/DOCKER_SETUP.md`, wenn Docker-Befehle, MCP-Profile oder Einstellungs-Standardwerte verändert werden.
