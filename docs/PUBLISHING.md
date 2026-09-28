# Version 1.2 auf GitHub veroeffentlichen

Das Repository enthaelt bereits einen Commit. Fuehre daher keine erneute Initialisierung aus.

1. Hole eine lokale Arbeitskopie und wechsle in ihren Ordner:

```sh
git clone https://github.com/contrango/afmchat.git
cd afmchat
```

2. Entpacke `afmchat-github-repository-v1.2.zip` in einen temporaeren Ordner. Kopiere den Inhalt des darin enthaltenen Ordners `afmchat` in den geklonten Ordner und bestaetige das Ueberschreiben geaenderter Dateien. Ersetze dabei nicht den versteckten `.git`-Ordner.

Zum Beispiel, wenn das ZIP in `~/Downloads` liegt:

```sh
unzip -o ~/Downloads/afmchat-github-repository-v1.2.zip -d /tmp/afmchat-v1.2
cp -R /tmp/afmchat-v1.2/afmchat/. .
```

3. Fuege die Aenderungen hinzu und veroeffentliche sie:

```sh
git add -A
git rm --cached --ignore-unmatch .DS_Store
git commit -m "Fix active model display (v1.2)"
git push origin main
```

GitHub muss dich authentifizieren; dein Konto benoetigt Schreibrechte fuer das Repository.

## Vor dem Push

- Pruefe, ob der Quellcode oeffentlich sein soll.
- Ergaenze eine passende `LICENSE`, wenn andere den Code verwenden oder weiterentwickeln duerfen. Es wurde absichtlich keine Lizenz geraten.
- Teile keine Chats, lokale Konfiguration, private SearXNG-URLs, Passwoerter oder API-Schluessel.
