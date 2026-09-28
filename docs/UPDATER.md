# App-Updates

AFM Chat prueft beim Start, ob seit der letzten Pruefung mindestens 24 Stunden vergangen sind. Solange die App offen ist, wird danach regelmaessig erneut geprueft. In der Seitenleiste kannst du jederzeit manuell nach einer neuen Version suchen.

## Was passiert bei einem Update?

1. Die App fragt das neueste stabile GitHub-Release ab. Vorabversionen werden ignoriert.
2. Wenn die Release-Version hoeher ist als die installierte App, erscheint in der Seitenleiste ein Button mit der Versionsnummer.
3. Ein Klick laedt das App-ZIP per HTTPS herunter. Die App vergleicht Dateigroesse und SHA-256-Pruefsumme mit den GitHub-Release-Metadaten.
4. Vor dem Neustart prueft die App die Bundle-ID und Version des enthaltenen App-Pakets.
5. Ein lokaler Helfer wartet, bis AFM Chat beendet ist, ersetzt das App-Bundle und startet die neue Version. Chatdaten bleiben im bisherigen Application-Support-Ordner.

## Anforderungen an GitHub Releases

- Verwende einen stabilen semantischen Release-Tag, zum Beispiel `v1.6`.
- Lade das gebaute macOS-App-Bundle als ZIP-Asset hoch, zum Beispiel `AFM.Chat.V1.6.ZIP`. Der Name muss mit `AFM.Chat.` oder `AFM-Chat-` beginnen. Source-Code- und Xcode-Projekt-ZIPs werden nicht installiert.
- Setze `CFBundleShortVersionString` beziehungsweise `MARKETING_VERSION` passend zum Release-Tag. Der Updater ignoriert Releases, deren Version nicht hoeher ist als die installierte Version.
- Der GitHub-Release muss fuer das Asset einen SHA-256-Digest bereitstellen. Der Updater bricht ab, wenn die Pruefsumme fehlt oder nicht stimmt.
- Verteile ein signiertes und fuer die gewuenschte macOS-Distribution passend notarisiertes App-Bundle.

## Speicherort und Grenzen

Der Updater kann eine App nur dann automatisch ersetzen, wenn der Ordner, in dem die `.app` liegt, fuer den angemeldeten Benutzer beschreibbar ist. Wenn das nicht der Fall ist, zum Beispiel bei einer geschuetzten Installation, erscheint eine Fehlermeldung. Installiere AFM Chat fuer automatische Updates in `~/Applications` oder aktualisiere die App manuell. Der Updater fordert keine Administratorrechte an.

Der Mechanismus ist fuer die GitHub-Distribution gedacht. Die App muss fuer den Update-Vorgang beendet werden; danach startet der Helfer die neue Version. Wenn der Austausch fehlschlaegt, stellt der Helfer nach Moeglichkeit die bisherige App wieder her.
