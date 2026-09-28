# Fehlerbehebung

## AFM Chat findet Docker nicht

- Stelle sicher, dass Docker Desktop gestartet ist.
- Prüfe unter **AFM Chat > Einstellungen > Docker MCP** den Eintrag **Docker-Programm**. Lasse ihn leer, damit die App automatisch sucht, oder wähle den tatsächlichen Docker-CLI-Pfad.
- Die automatische Suche berücksichtigt unter anderem `/opt/homebrew/bin/docker`, `/usr/local/bin/docker` und den Docker-Desktop-Pfad.

## Docker MCP verbindet sich nicht

- Prüfe, dass Docker MCP Toolkit aktiviert und das Profil exakt `web_grounding` benannt ist.
- Füge Fetch und Playwright im Docker-MCP-Katalog zum Profil hinzu und aktiviere sie.
- Vergewissere dich, dass das Profil im Docker MCP Gateway verfügbar ist.
- Beim ersten Tool-Aufruf kann Docker ein Image herunterladen; warte kurz und versuche es erneut.

## Fetch oder Playwright meldet `unknown tool`

- Die App kann fehlende Tool-Beschreibungen ergänzen, aber keine fehlenden MCP-Server installieren.
- Prüfe deshalb im Profil, dass Fetch und Playwright wirklich hinzugefügt und aktiviert sind.
- Docker-Gateway-Versionen können Toolnamen mit oder ohne Präfix liefern. Die App normalisiert einige Namensvarianten; ein fehlender Server bleibt trotzdem nicht verfügbar.

## SearXNG-Suche schlägt fehl

- Öffne `http://localhost:8888` im Browser auf dem Mac. Die SearXNG-Instanz muss dort erreichbar sein.
- In AFM Chat muss als URL standardmäßig `http://host.docker.internal:8888` stehen. Der MCP-Adapter läuft in einem Container; dort würde `localhost` auf den Adapter selbst zeigen.
- Wenn SearXNG in Docker läuft, veröffentliche den Host-Port 8888 auf den Container-Port 8080.
- Bei Suchwerkzeugen muss das Argument `query` eine nichtleere Zeichenfolge enthalten.

## MCP-Verbindung hängt oder endet mit Timeout

- Starte Docker Desktop neu und verbinde Web-Grounding erneut.
- Prüfe die Fehlermeldung im Statusbereich. AFM Chat zeigt Docker-Fehlerausgaben an, wenn der Prozess vor der MCP-Antwort beendet wird.
- Erlaube Docker den Zugriff auf das Netzwerk und die benötigten Images.

## Modell ist nicht bereit

- Prüfe, ob Foundation Models auf dem Mac und in der aktuellen macOS-Version verfügbar sind.
- Wenn das Modell verfügbar ist, zeigt AFM Chat `SystemLanguageModel.default.variant.displayName` an.

## Kopfzeile zeigt weiterhin den alten Text

Wenn du noch `Foundation Model · Auf diesem Mac` siehst, laeuft die alte installierte App. Version 1.2 zeigt `Aktives Modell: AFM 3 Core Advanced` oder die von macOS gemeldete Variante. Beende die alte App, oeffne das Projekt aus dem Version-1.2-ZIP, waehle **Product > Clean Build Folder** und starte genau diesen Build. Die Chatdaten bleiben beim Ersetzen der App unter `~/Library/Application Support/FMChat` erhalten.
