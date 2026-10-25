<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="NativeShot-Symbol">
</p>

<h1 align="center">NativeShot</h1>

<p align="center">
  <strong>Bildschirmfotos und Bildschirmaufnahmen, nativ für macOS.</strong><br>
  Kostenlos, Open Source und offline. Keine Konten, keine Telemetrie, keine Uploads.
</p>

<p align="center">
  <a href="https://github.com/PabloJuGo/NativeShot/releases/latest"><img src="https://img.shields.io/github/v/release/PabloJuGo/NativeShot?label=download" alt="Neueste Version"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15 oder neuer">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-universal-lightgrey" alt="Universal-Binary">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Lizenz-GPL--3.0-green" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <b>Deutsch</b> · <a href="README.pt.md">Português</a>
</p>

---

NativeShot sitzt in der Menüleiste und ersetzt das Bildschirmfoto-Werkzeug des Systems durch ein schnelleres, vielseitigeres Tool. Damit nehmen Sie jeden Bereich, jedes Fenster oder den ganzen Bildschirm auf, versehen die Aufnahme mit Anmerkungen, lesen den Text heraus oder heften sie über Ihre Arbeit. Auch Bildschirmaufnahmen mit Ton und Webcam sind möglich. Alles passiert auf Ihrem Mac.

<p align="center">
  <img src="docs/screenshots/editor.png" alt="Bildeditor" width="820">
</p>

## Funktionen

**Aufnahme**
- Bereich, Fenster (mit oder ohne Schatten), ganzer Bildschirm und **Scroll-Aufnahme** (vertikal, horizontal oder direkt als PDF).
- Lupe mit Koordinaten, eingefrorener Bildschirm, feste Seitenverhältnisse und Größen sowie Anpassung der Auswahl vor der Aufnahme.
- **Mehrere Bereiche** auf einmal: beim Ziehen ⌘ gedrückt halten und mit Return abschließen.
- Letzten Bereich oder letzte Aufnahme wiederholen, Selbstauslöser, Mauszeiger optional.
- Kann über einen geführten Assistenten `⌘⇧5` übernehmen und ändert dabei nie selbst die Systemeinstellungen.

**Nach der Aufnahme**
- Schwebende Miniatur zum Kopieren, Sichern, Bearbeiten, Anheften, Teilen, Ziehen, Löschen, Drucken und mehr. Alles geht auch per Tastatur.
- **Heften** Sie jede Aufnahme über alle Fenster, mit Zoom, Deckkraft und einer Sperre, bei der Klicks durchgereicht werden.
- **Texterkennung (OCR)** sowie QR- und Barcode-Erkennung direkt auf dem Gerät. Links werden angezeigt und nie ohne Nachfrage geöffnet.
- **Export-Manager**: Namensvorlage, Ordner, PNG, JPEG, HEIC, TIFF oder PDF, Qualität, Skalierung und Entfernen von Metadaten.

**Bildeditor**
- Pfeile, Linien, Formen, Text, Textmarker, nummerierte Zähler, Spotlight, Lupe, eingefügte Bilder und Ebenen.
- **Unumkehrbares Schwärzen** (Block, Verpixeln, Weichzeichnen): Beim Export werden die Pixel überschrieben, nicht nur verdeckt.
- Hintergründe und Rahmen für ansprechende Bildschirmfotos sowie bearbeitbare `.nshot`-Projekte.

**Bildschirmaufnahme**
- Bildschirm, Fenster oder Bereich; Systemton und Mikrofon; schwebende Webcam; hervorgehobene Klicks und Tastendrücke; Countdown und Pause.
- MP4 oder MOV in H.264 oder HEVC sowie GIF-Export.
- Videoeditor: Kürzen, Schneiden, automatischer Zoom auf Klicks, Cursor-Verfolgung, stumme Abschnitte und Untertitel.

**Mediathek**
- Lokaler, durchsuchbarer Verlauf, auch nach dem Text in Ihren Aufnahmen. Favoriten, Tags, Papierkorb und Aufbewahrungsregeln.
- **Private Sitzung**: Solange sie aktiv ist, wird nichts gespeichert.

<table>
  <tr>
    <td><img src="docs/screenshots/ocr-light.png" alt="Fenster mit erkanntem Text"></td>
    <td><img src="docs/screenshots/recorder-dark.png" alt="Bildschirmrekorder"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/export-light.png" alt="Export-Manager"></td>
    <td><img src="docs/screenshots/onboarding-dark.png" alt="Willkommensfenster"></td>
  </tr>
</table>

## Installation

1. Laden Sie **`NativeShot-<version>.dmg`** aus der [neuesten Version](https://github.com/PabloJuGo/NativeShot/releases/latest) herunter.
2. Öffnen Sie die Datei und ziehen Sie **NativeShot** in **Programme**.
3. Öffnen Sie NativeShot. Beim ersten Start meldet macOS, dass der Entwickler nicht überprüft werden kann, weil die App kostenlos und nicht von Apple notarisiert ist. So öffnen Sie sie trotzdem:
   - Gehen Sie zu **Systemeinstellungen › Datenschutz & Sicherheit**, scrollen Sie zur Meldung zu NativeShot, klicken Sie auf **Dennoch öffnen** und bestätigen Sie.
   - Oder im Terminal: `xattr -dr com.apple.quarantine /Applications/NativeShot.app`
4. Erlauben Sie die **Bildschirmaufnahme**, wenn macOS danach fragt (Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- und Systemaudioaufnahme). Mikrofon und Kamera werden nur abgefragt, wenn Sie sie für eine Aufnahme einschalten.

Voraussetzungen: macOS 15 Sequoia oder neuer, Apple silicon oder Intel. Die Oberfläche gibt es auf Englisch und Spanisch.

Den Download prüfen Sie mit der Datei `SHA256SUMS`, die jeder Version beiliegt: `shasum -a 256 -c SHA256SUMS`.

## Standard-Tastenkürzel

| Aktion | Kürzel |
|---|---|
| Aufnahmeauswahl | `⌃⌥⌘5` (oder `⌘⇧5` über Settings › Shortcuts) |
| Bereich | `⌃⌥⌘4` |
| Fenster | `⌃⌥⌘6` |
| Ganzer Bildschirm | `⌃⌥⌘3` |
| Text (OCR) | `⌃⌥⌘2` |

Während der Auswahl gilt: `Leertaste` wechselt zwischen Bereich und Fenster, Ziehen mit `⌘` fügt einen Bereich hinzu, die Pfeiltasten verschieben die Auswahl, `Return` bestätigt und `Esc` bricht ab. Alle Kürzel lassen sich in den Einstellungen ändern.

## Datenschutz

NativeShot stellt keine Verbindung zum Internet her. Es gibt kein Konto, keine Analyse, keine Absturzberichte und keine Cloud. Aufnahmen, erkannter Text und Ton verlassen Ihren Mac nie. Die einzige mögliche Netzwerkanfrage ist die Suche nach Updates, und auch die nur, wenn Sie auf **Check for updates…** klicken. Ihre Mediathek liegt in `~/Library/Application Support/NativeShot/`. Details stehen in [PRIVACY.md](PRIVACY.md).

## Aus dem Quellcode bauen

Sie brauchen nur die Xcode Command Line Tools (Swift 6.2), nicht Xcode selbst.

```sh
git clone https://github.com/PabloJuGo/NativeShot.git
cd NativeShot
scripts/test.sh             # Tests ausführen
scripts/bundle.sh           # build/NativeShot.app erzeugen
open build/NativeShot.app
```

`scripts/package.sh` erzeugt DMG und ZIP. Die Ad-hoc-Signatur ändert sich bei jedem Build, daher fragt macOS nach einem Neubau eventuell erneut nach der Bildschirmaufnahme. Das vermeiden Sie, indem Sie mit einer eigenen Identität signieren: `SIGN_IDENTITY="Mein Zertifikat" scripts/bundle.sh`.

## Mitwirken

Fehlerberichte, Übersetzungen und Pull Requests sind willkommen. Bitte lesen Sie zuerst [CONTRIBUTING.md](CONTRIBUTING.md). Sicherheitsprobleme melden Sie über [SECURITY.md](SECURITY.md), nicht über öffentliche Issues. Die Versionshinweise stehen in [CHANGELOG.md](CHANGELOG.md).

## Lizenz

NativeShot ist freie Software unter der [GNU General Public License v3.0](LICENSE). Sie dürfen es nutzen, untersuchen, verändern und weitergeben. Wer eine veränderte Version verbreitet, muss sie unter der GPL-3.0 und mit verfügbarem Quellcode weitergeben.
