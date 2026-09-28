# Veröffentlichen auf GitHub

Das vorbereitete Projekt ist für `https://github.com/contrango/afmchat.git` gedacht. Beim Erstellen dieser Dateien war das Repository leer. Aus dieser Umgebung kann kein Commit zu GitHub gepusht werden; der Inhalt kann aber mit den folgenden Schritten veröffentlicht werden.

Nach dem Entpacken des Repository-ZIPs in den Ordner `afmchat` wechseln und ausführen:

```sh
git init -b main
git add .
git commit -m "Initial commit: AFM Chat"
git remote add origin https://github.com/contrango/afmchat.git
git push -u origin main
```

GitHub muss dich beim Push authentifizieren und dein Konto muss Schreibrechte für das Repository haben. Falls du ein anderes Repository verwendest, passe die Remote-URL an. Die Schritte setzen voraus, dass das Ziel-Repository noch keine Commits enthält.

## Vor dem ersten Push

- Prüfe, ob der Quellcode öffentlich sein soll.
- Ergänze eine passende `LICENSE`, wenn andere den Code verwenden oder weiterentwickeln dürfen. Es wurde absichtlich keine Lizenz geraten.
- Teile keine Chats, lokale Konfiguration, private SearXNG-URLs, Passwörter oder API-Schlüssel. `.gitignore` schliesst typische Xcode-Build-Artefakte und lokale Zustandsdateien aus.
