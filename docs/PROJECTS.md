# Projekte und lokale Dokumente

## Projekte anlegen

1. Klicke in der Seitenleiste neben **Projekte** auf **+**.
2. Vergib einen Namen und schreibe optional einen Projekt-Prompt. Dieser gilt fuer neue Nachrichten in allen Chats dieses Projekts. Der globale System-Prompt bleibt die allgemeine Grundeinstellung.
3. Fuege PDFs, Textdateien (zum Beispiel MD, JSON und XML) oder PNG-/JPEG-Bilder hinzu.
4. Speichere das Projekt. AFM Chat legt einen neuen Chat im Projekt an. Weitere Chats erzeugst du mit **Neuer Chat**, solange das Projekt ausgewaehlt ist.

## Wie Dokumente verwendet werden

Die App liest Dokumente lokal ein. Bei PDFs wird auslesbarer Text mit Seitenmarkierungen gespeichert; bei Bildern speichert AFM Chat das Ergebnis der lokalen Vision-Analyse. Die Originaldateien bleiben am urspruenglichen Speicherort. Die ausgelesenen Projekttexte liegen in `~/Library/Application Support/FMChat/Projects`.

Bei der ersten Frage indexiert AFM Chat die Projektabschnitte lokal. Die Suche kombiniert Satz-Embeddings aus Apples NaturalLanguage-Framework mit BM25-Stichwortsuche (hybride Suche). Dadurch koennen auch sinngleiche Formulierungen gefunden werden. Die Embeddings und der Suchindex bleiben unter `~/Library/Application Support/FMChat/Projects` auf dem Mac; es gibt keine externen API-Aufrufe und keinen separaten Vektorserver. Bei geaenderten oder neu hinzugefuegten Dokumenten wird der Index bei der naechsten Frage neu aufgebaut.

Die semantische Bewertung verwendet sprachspezifische Satz-Embeddings. Sie greift, wenn Dokumentabschnitt und Anfrage dieselbe unterstuetzte Sprache haben und macOS das entsprechende Embedding bereitstellt. Andernfalls bleibt BM25 als lokaler Fallback aktiv. Bei einer erstmaligen Indexierung kann die erste Antwort deshalb etwas laenger dauern.

Projekt-Prompts und Dokumentauszuege werden bei normalem Chatten nicht an Docker, SearXNG oder das Internet gesendet. Wenn du Web-Grounding nutzt, werden nur die dafuer benoetigten Suchanfragen und Webseiten extern abgerufen.

## Verwalten und loeschen

- Waehle ein Projekt aus, um nur dessen Chats anzuzeigen. **Allgemeine Chats** bleiben getrennt.
- Ueber das Drei-Punkte-Menue kannst du Projektname, Prompt und Dokumente bearbeiten.
- Beim Loeschen eines Projekts werden die lokalen Projekt-Dokumentauszuege entfernt. Die Chats bleiben erhalten und werden zu allgemeinen Chats.
- Aeltere Chats ohne Projektzuordnung werden beim ersten Start nach dem Update als allgemeine Chats geladen.

## Grenzen

- Pro Projekt sind bis zu 50 Dokumente erlaubt. Pro Dokument werden bis zu 120.000 Zeichen ausgelesen; bei laengeren Texten wird der Auszug gekuerzt.
- Gescannte PDFs ohne selektierbaren Text werden noch nicht per OCR verarbeitet.
- Fuer unterschiedliche Sprachen zwischen Anfrage und Dokumenten kann die semantische Aehnlichkeit nicht direkt verglichen werden; die lokale Stichwortsuche bleibt als Fallback aktiv.
