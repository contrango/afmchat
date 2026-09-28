# Version 1.3 auf GitHub veroeffentlichen

Das Repository enthaelt bereits einen Commit. Fuehre daher keine erneute Initialisierung aus.

1. Hole eine lokale Arbeitskopie und wechsle in ihren Ordner:

```sh
git clone https://github.com/contrango/afmchat.git
cd afmchat
```

2. Entpacke `afmchat-github-repository-v1.3.zip` in einen temporaeren Ordner. Kopiere den Inhalt des darin enthaltenen Ordners `afmchat` in den geklonten Ordner und bestaetige das Ueberschreiben geaenderter Dateien. Ersetze dabei nicht den versteckten `.git`-Ordner.

Zum Beispiel, wenn das ZIP in `~/Downloads` liegt:

```sh
unzip -o ~/Downloads/afmchat-github-repository-v1.3.zip -d /tmp/afmchat-v1.3
cp -R /tmp/afmchat-v1.3/afmchat/. .
```

3. Fuege die Aenderungen hinzu und veroeffentliche sie:

```sh
git add -A
git rm --cached --ignore-unmatch .DS_Store
git commit -m "Add configurable system prompt (v1.3)"
git push origin main
```

GitHub muss dich authentifizieren; dein Konto benoetigt Schreibrechte fuer das Repository.

## Vor dem Push

- Pruefe, ob der Quellcode oeffentlich sein soll.
- Ergaenze eine passende `LICENSE`, wenn andere den Code verwenden oder weiterentwickeln duerfen. Es wurde absichtlich keine Lizenz geraten.
- Teile keine Chats, lokale Konfiguration, private SearXNG-URLs, Passwoerter oder API-Schluessel.


## macOS-App erneut hochladen

Für einen Upload muss ein neues Archiv mit Hardened Runtime erstellt werden. Im App-Target ist `ENABLE_HARDENED_RUNTIME = YES` gesetzt. Prüfe die Option zusätzlich in Xcode unter **Signing & Capabilities**, wähle das passende Signing-Team und erstelle das Archiv neu. Der aktuelle Quellstand verwendet Version 1.3, Build 5.
