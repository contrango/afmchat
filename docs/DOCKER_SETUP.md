# Docker MCP und SearXNG einrichten

Diese Anleitung beschreibt die Docker-Seite der optionalen Web-Recherche in AFM Chat. Es sind drei Bausteine zu unterscheiden:

1. **Docker MCP Gateway** stellt die MCP-Server eines Docker-Profils bereit.
2. **Fetch und Playwright** sind MCP-Server im Profil `web_grounding`. Docker startet ihre Container erst, wenn ein Tool benötigt wird.
3. **SearXNG** ist die Suchmaschine unter `http://localhost:8888`. Zusätzlich startet AFM Chat einen separaten SearXNG-MCP-Adapter-Container.

AFM Chat kommuniziert mit Gateway und SearXNG-MCP-Adapter über Standard Input/Output (stdio). Für die App muss kein eigener MCP-HTTP-Port geöffnet werden.

## 1. Voraussetzungen

- Docker Desktop ist installiert und gestartet.
- Docker MCP Toolkit ist in Docker Desktop verfügbar.
- Das Docker-CLI `docker` ist aus der App heraus erreichbar.
- SearXNG ist auf dem Mac über Port `8888` erreichbar.

AFM Chat sucht Docker automatisch an üblichen macOS-Pfaden und im `PATH`. Falls die App Docker nicht findet, trage unter **AFM Chat > Einstellungen > Docker MCP** den vollständigen Pfad zum Docker-Programm ein.

## 2. Docker-MCP-Profil `web_grounding`

1. Öffne Docker Desktop und den Bereich **MCP Toolkit**.
2. Erstelle ein Profil mit dem exakten Namen `web_grounding` oder verwende ein bestehendes Profil.
3. Füge im MCP-Katalog die Server **Fetch** und **Playwright** zu diesem Profil hinzu und aktiviere sie.
4. Prüfe, dass das Profil für den MCP Gateway verfügbar ist.

Docker MCP Toolkit verwendet Profile, um festzulegen, welche Server ein Gateway-Aufruf bereitstellt. AFM Chat startet den Gateway mit dem in den Einstellungen eingetragenen Profilnamen. Der Standardaufruf lautet:

```sh
docker mcp gateway run --profile web_grounding
```

Die Menüeinträge in Docker Desktop können sich je nach Version leicht unterscheiden. Siehe die [Docker-Anleitung zu MCP Profiles](https://docs.docker.com/ai/mcp-catalog-and-toolkit/profiles/) und das [Docker MCP Toolkit](https://docs.docker.com/ai/mcp-catalog-and-toolkit/toolkit/).

### Welche Docker-Tools AFM Chat nutzt

AFM Chat lässt nur diese Web-Tools des Gateways zum Modell durch:

- **Fetch**: `fetch` oder `fetch:fetch` liest eine angegebene URL und liefert den Seiteninhalt.
- **Playwright**: `browser_navigate`, `browser_snapshot`, `browser_navigate_back` und gegebenenfalls `browser_wait_for`.

Die Playwright-Funktionen sind absichtlich nur lesend. Klicken, Formulare absenden, Inhalte verändern oder Seiten löschen ist nicht freigegeben.

**Wichtig:** AFM Chat kann Tool-Beschreibungen für Fetch und Playwright ergänzen, wenn eine Docker-Version sie beim Auflisten nicht mitliefert. Das installiert oder aktiviert aber keinen fehlenden Server. Wenn Fetch oder Playwright nicht im Profil eingerichtet ist, schlägt der Tool-Aufruf fehl.

## 3. SearXNG auf Port 8888

SearXNG muss vom Mac unter `http://localhost:8888` erreichbar sein. Wenn du SearXNG bereits dort betreibst, kannst du diesen Abschnitt überspringen.

Ein möglicher Start einer SearXNG-Instanz mit persistenten Konfigurations- und Cache-Verzeichnissen ist:

```sh
mkdir -p searxng/config searxng/data
docker run --name searxng -d --restart unless-stopped -p 8888:8080 -v "$PWD/searxng/config:/etc/searxng" -v "$PWD/searxng/data:/var/cache/searxng" docker.io/searxng/searxng:latest
```

Danach sollte die SearXNG-Weboberfläche auf dem Mac unter `http://localhost:8888` erreichbar sein. Die offizielle Anleitung findest du in der [SearXNG-Docker-Dokumentation](https://docs.searxng.org/admin/installation-docker.html).

### Warum in AFM Chat `host.docker.internal` steht

AFM Chat startet den SearXNG-MCP-Adapter in einem eigenen Docker-Container. Innerhalb dieses Containers verweist `localhost` auf den Adapter-Container, nicht auf den Mac. Deshalb lautet die Standardadresse:

```text
http://host.docker.internal:8888
```

Wenn SearXNG ebenfalls in Docker läuft, muss sein interner Port `8080` auf den Host-Port `8888` veröffentlicht sein (zum Beispiel `8888:8080`). Verwende in AFM Chat nicht `http://localhost:8888` als Adapter-Adresse, sofern SearXNG nicht im selben Container läuft.

## 4. AFM-Chat-Einstellungen

Unter **AFM Chat > Einstellungen > Docker MCP** und **SearXNG** sind diese Standardwerte hinterlegt:

| Einstellung | Standardwert | Zweck |
|---|---|---|
| Docker-Programm | automatisch | Pfad zum Docker-CLI, falls die automatische Suche nicht greift |
| Docker-MCP-Profil | `web_grounding` | Profil mit Fetch und Playwright |
| SearXNG-URL | `http://host.docker.internal:8888` | Adresse der SearXNG-Webinstanz aus dem Adapter-Container |
| SearXNG-MCP-Image | `isokoliuk/mcp-searxng:latest` | MCP-Adapter, der SearXNG-Suchanfragen entgegennimmt |
| Temporäres Verzeichnis | macOS-Standard | Arbeitsbereich für Upload-Dateien und MCP-Prozesse |

Die aktuellen Werte lassen sich in den Einstellungen wiederherstellen. Nach dem Speichern der Verbindungsdaten versucht die App, die MCP-Verbindung neu aufzubauen.

## 5. Was die App beim Verbinden startet

AFM Chat versucht beim Start, die Webdienste zu verbinden. Wenn die Verbindung fehlschlägt, kannst du sie über den Web-Grounding-Status in der Seitenleiste erneut starten. Die App startet selbst diese Prozesse:

```sh
docker mcp gateway run --profile web_grounding
docker run -i --rm -e SEARXNG_URL isokoliuk/mcp-searxng:latest
```

Beim zweiten Aufruf setzt die App die Umgebungsvariable `SEARXNG_URL` auf den Wert aus den Einstellungen. `-i` hält stdin für MCP offen; `--rm` entfernt den Adapter-Container nach Ende der Verbindung. Du musst diese Befehle nicht in einem Terminal starten.

Der Gateway-Prozess läuft während der Verbindung. Fetch- und Playwright-Server im Profil werden durch Docker MCP bei Bedarf gestartet, also erst wenn das Modell das jeweilige Tool aufruft. Beim ersten Aufruf kann Docker Images herunterladen; das kann einige Zeit dauern.

Der SearXNG-MCP-Adapter wird beim Verbindungsaufbau gestartet. Die SearXNG-Webinstanz selbst muss bereits laufen.

## 6. Verbindung testen

1. Öffne `http://localhost:8888` im Browser des Macs und stelle sicher, dass SearXNG antwortet.
2. Prüfe in Docker Desktop, dass `web_grounding` Fetch und Playwright enthält.
3. Öffne AFM Chat, speichere die passenden Einstellungen und verbinde Web-Grounding über den Statusbereich in der Seitenleiste.
4. Teste eine Suche, zum Beispiel: **Suche in SearXNG nach aktuellen Informationen zu ...**
5. Teste Fetch mit einer konkreten URL und Playwright mit dem Lesen einer Seite.

Bei SearXNG-Suchen ist das Pflichtfeld `query`. Verwende dieses Feld statt `q` oder `prompt`.

## 7. Netzwerk und Datenschutz

- Das Foundation Model läuft über Apples Foundation-Models-Framework auf dem Gerät, sofern es verfügbar ist.
- SearXNG erhält Suchbegriffe. Abhängig von deiner SearXNG-Konfiguration werden Suchanfragen an externe Suchmaschinen weitergegeben.
- Fetch und Playwright rufen die vom Modell angeforderten Webseiten ab.
- Sende keine vertraulichen Daten an externe Webseiten oder Suchmaschinen.

## Weiterführende Links

- [Docker MCP Toolkit](https://docs.docker.com/ai/mcp-catalog-and-toolkit/toolkit/)
- [Docker MCP Profiles](https://docs.docker.com/ai/mcp-catalog-and-toolkit/profiles/)
- [Docker MCP CLI](https://docs.docker.com/ai/mcp-catalog-and-toolkit/cli/)
- [SearXNG Docker-Installation](https://docs.searxng.org/admin/installation-docker.html)
