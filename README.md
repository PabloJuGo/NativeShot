<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="NativeShot icon">
</p>

<h1 align="center">NativeShot</h1>

<p align="center">
  <strong>Screenshots and screen recordings, native to macOS.</strong><br>
  Free, open source, offline. No accounts, no telemetry, no uploads.
</p>

<p align="center">
  <a href="https://github.com/PabloJuGo/NativeShot/releases/latest"><img src="https://img.shields.io/github/v/release/PabloJuGo/NativeShot?label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-universal-lightgrey" alt="Universal binary">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0"></a>
</p>

<p align="center">
  <b>English</b> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt.md">Português</a>
</p>

---

NativeShot lives in your menu bar and replaces the system screenshot tool with something faster and more capable: capture any area, window or screen, annotate it, pull text out of it, pin it on top of your work, or record your screen with sound and webcam. Everything happens on your Mac.

<p align="center">
  <img src="docs/screenshots/editor.png" alt="Image editor" width="820">
</p>

## Features

**Capture**
- Area, window (with or without shadow), full screen and **scrolling capture** (vertical, horizontal, or straight to PDF).
- Magnifier with pixel coordinates, frozen screen, fixed aspect ratios and sizes, adjustable selection before capturing.
- **Multiple regions** in one go: hold ⌘ while dragging, press Return to finish.
- Repeat the last area or the last capture, self-timer, optional cursor.
- Can take over `⌘⇧5` with a guided assistant (it never edits your system settings for you).

**After the capture**
- Floating thumbnail with copy, save, edit, pin, share, drag and drop, delete, print and more. Fully keyboard-driven.
- **Pin** any capture on top of every window: zoom, opacity, click-through lock.
- **Text recognition (OCR)** and QR/barcode reading on device. Links are shown, never opened without asking.
- **Export manager**: name template, folder, PNG, JPEG, HEIC, TIFF or PDF, quality, scale, metadata removal.

**Image editor**
- Arrows, lines, shapes, text, highlighter, numbered counters, spotlight, magnifier, inserted images, layers.
- **Irreversible redaction** (solid block, pixelate, blur): the pixels are rewritten on export, not just covered.
- Backgrounds and frames for presentable screenshots; editable `.nshot` projects.

**Screen recording**
- Screen, window or area; system audio and microphone; floating webcam; highlighted clicks and keystrokes; countdown and pause.
- MP4 or MOV, H.264 or HEVC. GIF export.
- Video editor: trim, cut, automatic zoom on clicks, cursor follow, muted ranges, captions.

**Library**
- Local, searchable history (including the text inside your captures), favourites, tags, trash, retention rules.
- **Private session**: while it is on, nothing is stored.

<table>
  <tr>
    <td><img src="docs/screenshots/ocr-light.png" alt="Recognized text window"></td>
    <td><img src="docs/screenshots/recorder-dark.png" alt="Screen recorder"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/export-light.png" alt="Export manager"></td>
    <td><img src="docs/screenshots/onboarding-dark.png" alt="Welcome window"></td>
  </tr>
</table>

## Install

1. Download **`NativeShot-1.0.0.dmg`** from the [latest release](https://github.com/PabloJuGo/NativeShot/releases/latest).
2. Open it and drag **NativeShot** to **Applications**.
3. Open NativeShot. The first time, macOS will say it cannot verify the developer, because the app is free and not notarized by Apple. To open it anyway:
   - open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to the NativeShot message, then confirm;
   - or, in Terminal: `xattr -dr com.apple.quarantine /Applications/NativeShot.app`
4. Grant **Screen Recording** when asked (System Settings › Privacy & Security › Screen & System Audio Recording). Microphone and camera are only requested if you turn them on for a recording.

Requirements: macOS 15 Sequoia or later, Apple silicon or Intel. The interface is available in English and Spanish.

You can check the download with the `SHA256SUMS` file attached to each release: `shasum -a 256 -c SHA256SUMS`.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Capture selector | `⌃⌥⌘5` (or `⌘⇧5` through Settings › Shortcuts) |
| Area | `⌃⌥⌘4` |
| Window | `⌃⌥⌘6` |
| Full screen | `⌃⌥⌘3` |
| Text (OCR) | `⌃⌥⌘2` |

While selecting: `Space` toggles area/window, `⌘`-drag adds a region, arrows nudge, `Return` confirms, `Esc` cancels. Every shortcut can be changed in Settings.

## Privacy

NativeShot does not connect to the internet. There is no account, analytics, crash reporting or cloud. Captures, recognized text and audio never leave your Mac. The only network request it can make is the update check, and only when you click **Check for updates…**. Your library lives in `~/Library/Application Support/NativeShot/`. Details in [PRIVACY.md](PRIVACY.md).

## Build from source

You only need the Xcode Command Line Tools (Swift 6.2). Xcode itself is not required.

```sh
git clone https://github.com/PabloJuGo/NativeShot.git
cd NativeShot
scripts/test.sh             # run the test suite
scripts/bundle.sh           # build build/NativeShot.app
open build/NativeShot.app
```

`scripts/package.sh` produces the DMG and ZIP. Ad-hoc signatures change on every build, so macOS may ask for Screen Recording again after rebuilding; sign with your own identity to avoid it: `SIGN_IDENTITY="My certificate" scripts/bundle.sh`.

## Contributing

Bug reports, translations and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Security issues go through [SECURITY.md](SECURITY.md), not public issues. Release notes are in [CHANGELOG.md](CHANGELOG.md).

## License

NativeShot is free software under the [GNU General Public License v3.0](LICENSE). You can use, study, change and share it; if you distribute a modified version, it must stay under GPL-3.0 with its source code available.
