# AFM Chat

AFM Chat v1.4 ist eine native macOS-Chat-App für Apples Foundation Models. Sie nutzt Apples lokales Swift-Framework, speichert Gespräche lokal und kann optionale Web-Recherche über Docker MCP und SearXNG einbinden.

**GitHub:** https://github.com/contrango/afmchat

## Funktionen

- SwiftUI-Oberfläche mit gespeicherten und fortsetzbaren Chats.
- Anzeige der aktiven Modellvariante über `SystemLanguageModel.default.variant.displayName`.
- Lokale Analyse von PDFs, Text- und Quelldateien sowie PNG-/JPEG-Bildern.
- Optionale Web-Recherche über SearXNG, Fetch und einen nur lesenden Playwright-Zugriff.
- Ein anpassbarer System-Prompt für das grundlegende Verhalten, gespeichert auf dem Mac und bei jeder neuen Anfrage berücksichtigt.
- Prueft taeglich GitHub Releases und bietet neue Versionen als Ein-Klick-Update mit Pruefsumme und automatischem Neustart an.
- Einstellungen für System-Prompt, temporäres Upload-Verzeichnis, Docker CLI, Docker-MCP-Profil und SearXNG.

## Voraussetzungen

- macOS 27 oder neuer und Xcode 27 oder neuer.
- Ein Mac, auf dem Apple Foundation Models verfügbar sind.
- Optional für Web-Recherche: Docker Desktop mit MCP Toolkit sowie eine erreichbare SearXNG-Instanz.

## Bauen und starten (Version 1.4, Build 1)

1. `AFM Chat.xcodeproj` in Xcode öffnen.
2. Das Scheme `AFM Chat` und den Mac als Run Destination auswählen.
3. **Run** drücken.

Alternativ im Projektordner:

```sh
xcodebuild -project "AFM Chat.xcodeproj" -scheme "AFM Chat" -configuration Debug -derivedDataPath build-v1.4 CODE_SIGNING_ALLOWED=NO build
open "build-v1.4/Build/Products/Debug/AFM Chat.app"
```

## Foundation Model

Die App fragt `SystemLanguageModel.default` ab. macOS stellt die auf dem Gerät verfügbare Standardvariante bereit; die App erzwingt nicht selbst Core oder Advanced. Der Modellname wird in der Kopfzeile und im Statusbereich angezeigt. Verfügbarkeit und Variante hängen von Gerät, Betriebssystem und Modellbereitstellung ab.

## Web-Recherche mit Docker

Docker ist optional. Für Web-Recherche benötigst du:

1. Ein Docker-MCP-Profil namens `web_grounding` mit den MCP-Servern **Fetch** und **Playwright**.
2. Eine SearXNG-Instanz, die auf dem Mac unter `http://localhost:8888` erreichbar ist.
3. Eine aktive Web-Grounding-Verbindung in AFM Chat. Die App versucht die Verbindung beim Start und bietet in der Seitenleiste eine Schaltfläche zum erneuten Verbinden.

AFM Chat startet den Docker-MCP-Gateway-Prozess und den SearXNG-MCP-Adapter selbst. Fetch und Playwright müssen nicht vorab manuell gestartet werden; Docker startet sie bei Bedarf, wenn das jeweilige Tool aufgerufen wird. Die SearXNG-Instanz selbst muss laufen.

Die vollständige Anleitung steht in [Docker MCP und SearXNG einrichten](docs/DOCKER_SETUP.md). Siehe auch [Updater](docs/UPDATER.md), [Architektur](docs/ARCHITECTURE.md), [Fehlerbehebung](docs/TROUBLESHOOTING.md), [Entwicklung](CONTRIBUTING.md) und [GitHub-Veröffentlichung](docs/PUBLISHING.md).

## Daten und Datenschutz

Chatverläufe und Foundation-Models-Transkripte bleiben standardmäßig auf dem Mac unter `~/Library/Application Support/FMChat/conversations.json`. Uploads werden für die Verarbeitung vorübergehend im gewählten Arbeitsverzeichnis abgelegt und danach entfernt. Chatverläufe können extrahierten Text oder Analysehinweise enthalten.

Web-Recherche ist nicht vollständig lokal: Suchanfragen gehen an die konfigurierte SearXNG-Instanz und können von dort an externe Suchmaschinen weitergeleitet werden. Fetch und Playwright rufen angeforderte Internetseiten ab. Sende keine vertraulichen Daten an externe Webseiten oder Suchmaschinen. Die Update-Prüfung fragt GitHub nach der neuesten Versionsnummer und den Release-Prüfdaten; das App-ZIP wird erst heruntergeladen, wenn du auf den Update-Button klickst.

## Lizenz

Dieses Repository enthält derzeit keine Lizenzdatei. Eine Veröffentlichung auf GitHub allein erteilt keine Wiederverwendungsrechte. Vor externer Weiterverwendung oder Beiträgen sollte eine passende Lizenz ergänzt werden.
