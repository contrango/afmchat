# Projekte und lokale Dokumente

## Projekte anlegen

1. Klicke in der Seitenleiste neben **Projekte** auf **+**.
2. Vergib einen Namen und schreibe optional einen Projekt-Prompt. Dieser gilt fuer neue Nachrichten in allen Chats dieses Projekts. Der globale System-Prompt bleibt die allgemeine Grundeinstellung.
3. Fuege PDFs, Textdateien (zum Beispiel MD, JSON und XML) oder PNG-/JPEG-Bilder hinzu.
4. Speichere das Projekt. AFM Chat legt einen neuen Chat im Projekt an. Weitere Chats erzeugst du mit **Neuer Chat**, solange das Projekt ausgewaehlt ist.

## Wie Dokumente verwendet werden

Die App liest Dokumente lokal ein. Bei PDFs wird auslesbarer Text mit Seitenmarkierungen gespeichert; bei Bildern speichert AFM Chat das Ergebnis der lokalen Vision-Analyse. Die Originaldateien bleiben am urspruenglichen Speicherort. Die ausgelesenen Projekttexte liegen in `~/Library/Application Support/FMChat/Projects`.

Bei einer Frage fuehrt AFM Chat eine lokale Stichwortsuche (BM25) ueber die Projektabschnitte aus. Nur die hoechstbewerteten Abschnitte kommen in den Modellkontext. Dateiname und PDF-Seite werden fuer Quellenhinweise mitgegeben. Das ist keine semantische Suche: Andere Formulierungen ohne gemeinsame Stichwoerter koennen passende Inhalte verfehlen. Es werden keine Embeddings berechnet und kein separater Vektorserver benoetigt.

Projekt-Prompts und Dokumentauszuege werden bei normalem Chatten nicht an Docker, SearXNG oder das Internet gesendet. Wenn du Web-Grounding nutzt, werden nur die dafuer benoetigten Suchanfragen und Webseiten extern abgerufen.

## Verwalten und loeschen

- Waehle ein Projekt aus, um nur dessen Chats anzuzeigen. **Allgemeine Chats** bleiben getrennt.
- Ueber das Drei-Punkte-Menue kannst du Projektname, Prompt und Dokumente bearbeiten.
- Beim Loeschen eines Projekts werden die lokalen Projekt-Dokumentauszuege entfernt. Die Chats bleiben erhalten und werden zu allgemeinen Chats.
- Aeltere Chats ohne Projektzuordnung werden beim ersten Start nach dem Update als allgemeine Chats geladen.

## Grenzen der ersten Version

- Pro Projekt sind bis zu 50 Dokumente erlaubt. Pro Dokument werden bis zu 120.000 Zeichen ausgelesen; bei laengeren Texten wird der Auszug gekuerzt.
- Gescannte PDFs ohne selektierbaren Text werden noch nicht per OCR verarbeitet.
- Die Stichwortsuche findet keine inhaltlichen Synonyme, wenn sich relevante Begriffe nicht ueberschneiden. Eine optionale semantische Suche waere ein spaeterer Ausbauschritt.
