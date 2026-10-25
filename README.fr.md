<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Icône de NativeShot">
</p>

<h1 align="center">NativeShot</h1>

<p align="center">
  <strong>Captures et enregistrements d’écran, natifs pour macOS.</strong><br>
  Gratuit, open source et hors ligne. Ni compte, ni télémétrie, ni envoi de données.
</p>

<p align="center">
  <a href="https://github.com/PabloJuGo/NativeShot/releases/latest"><img src="https://img.shields.io/github/v/release/PabloJuGo/NativeShot?label=t%C3%A9l%C3%A9charger" alt="Dernière version"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15 ou ultérieur">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-universel-lightgrey" alt="Binaire universel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-GPL--3.0-green" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.es.md">Español</a> · <b>Français</b> · <a href="README.de.md">Deutsch</a> · <a href="README.pt.md">Português</a>
</p>

---

NativeShot s’installe dans la barre des menus et remplace l’outil de capture du système par un outil plus rapide et plus complet. Il capture n’importe quelle zone, fenêtre ou écran, permet de l’annoter, d’en extraire le texte ou de l’épingler au-dessus de votre travail, et enregistre l’écran avec le son et la webcam. Tout se passe sur votre Mac.

<p align="center">
  <img src="docs/screenshots/editor.png" alt="Éditeur d’images" width="820">
</p>

## Fonctionnalités

**Capture**
- Zone, fenêtre (avec ou sans ombre), plein écran et **capture avec défilement** (verticale, horizontale ou directement en PDF).
- Loupe avec coordonnées, écran figé, proportions et tailles fixes, et ajustement de la sélection avant la capture.
- **Plusieurs zones** d’un coup : maintenez ⌘ en faisant glisser, puis appuyez sur Retour pour terminer.
- Répéter la dernière zone ou la dernière capture, minuteur et curseur en option.
- Peut prendre en charge `⌘⇧5` grâce à un assistant guidé, qui ne modifie jamais les réglages du système à votre place.

**Après la capture**
- Vignette flottante pour copier, enregistrer, modifier, épingler, partager, glisser-déposer, supprimer, imprimer, et plus encore. Tout se fait au clavier.
- **Épinglez** n’importe quelle capture au-dessus de toutes les fenêtres, avec zoom, opacité et verrouillage pour que les clics la traversent.
- **Reconnaissance de texte (OCR)** et lecture de QR codes et de codes-barres sur l’appareil. Les liens sont affichés et ne s’ouvrent jamais sans votre accord.
- **Gestionnaire d’export** : modèle de nom, dossier, PNG, JPEG, HEIC, TIFF ou PDF, qualité, échelle et suppression des métadonnées.

**Éditeur d’images**
- Flèches, lignes, formes, texte, surligneur, compteurs numérotés, projecteur, loupe, images insérées et calques.
- **Masquage irréversible** (bloc, pixellisation, flou) : les pixels sont réécrits à l’export, pas seulement recouverts.
- Arrière-plans et cadres pour des captures soignées, et projets `.nshot` modifiables.

**Enregistrement d’écran**
- Écran, fenêtre ou zone ; audio du système et micro ; webcam flottante ; clics et touches mis en évidence ; compte à rebours et pause.
- MP4 ou MOV, en H.264 ou HEVC, et export en GIF.
- Éditeur vidéo : rognage, coupes, zoom automatique sur les clics, suivi du curseur, passages muets et sous-titres.

**Bibliothèque**
- Historique local avec recherche, y compris dans le texte de vos captures. Favoris, étiquettes, corbeille et règles de conservation.
- **Session privée** : tant qu’elle est active, rien n’est conservé.

<table>
  <tr>
    <td><img src="docs/screenshots/ocr-light.png" alt="Fenêtre du texte reconnu"></td>
    <td><img src="docs/screenshots/recorder-dark.png" alt="Enregistreur d’écran"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/export-light.png" alt="Gestionnaire d’export"></td>
    <td><img src="docs/screenshots/onboarding-dark.png" alt="Fenêtre de bienvenue"></td>
  </tr>
</table>

## Installation

1. Téléchargez **`NativeShot-<version>.dmg`** depuis la [dernière version](https://github.com/PabloJuGo/NativeShot/releases/latest).
2. Ouvrez-le et faites glisser **NativeShot** dans **Applications**.
3. Ouvrez NativeShot. La première fois, macOS indique qu’il ne peut pas vérifier le développeur, car l’app est gratuite et n’est pas notarisée par Apple. Pour l’ouvrir quand même :
   - ouvrez **Réglages Système › Confidentialité et sécurité**, faites défiler jusqu’au message concernant NativeShot, cliquez sur **Ouvrir quand même** et confirmez ;
   - ou, dans le Terminal : `xattr -dr com.apple.quarantine /Applications/NativeShot.app`
4. Autorisez l’**enregistrement de l’écran** lorsque macOS le demande (Réglages Système › Confidentialité et sécurité › Enregistrement de l’écran et de l’audio du système). Le micro et la caméra ne sont demandés que si vous les activez pour un enregistrement.

Configuration requise : macOS 15 Sequoia ou ultérieur, avec Apple silicon ou Intel. L’interface est disponible en anglais et en espagnol.

Pour vérifier le téléchargement, utilisez le fichier `SHA256SUMS` joint à chaque version : `shasum -a 256 -c SHA256SUMS`.

## Raccourcis par défaut

| Action | Raccourci |
|---|---|
| Sélecteur de capture | `⌃⌥⌘5` (ou `⌘⇧5` via Settings › Shortcuts) |
| Zone | `⌃⌥⌘4` |
| Fenêtre | `⌃⌥⌘6` |
| Plein écran | `⌃⌥⌘3` |
| Texte (OCR) | `⌃⌥⌘2` |

Pendant la sélection : `Espace` alterne entre zone et fenêtre, glisser avec `⌘` ajoute une zone, les flèches ajustent la sélection, `Retour` valide et `Échap` annule. Tous les raccourcis sont modifiables dans les réglages.

## Confidentialité

NativeShot ne se connecte pas à internet. Il n’y a ni compte, ni statistiques, ni rapports de plantage, ni cloud. Les captures, le texte reconnu et l’audio ne quittent jamais votre Mac. La seule requête réseau possible est la recherche de mises à jour, et seulement quand vous cliquez sur **Check for updates…**. Votre bibliothèque se trouve dans `~/Library/Application Support/NativeShot/`. Plus de détails dans [PRIVACY.md](PRIVACY.md).

## Compiler depuis les sources

Seuls les Command Line Tools de Xcode (Swift 6.2) sont nécessaires, pas Xcode.

```sh
git clone https://github.com/PabloJuGo/NativeShot.git
cd NativeShot
scripts/test.sh             # lance les tests
scripts/bundle.sh           # produit build/NativeShot.app
open build/NativeShot.app
```

`scripts/package.sh` produit le DMG et le ZIP. La signature ad hoc change à chaque compilation, donc macOS peut redemander l’autorisation d’enregistrement de l’écran. Pour l’éviter, signez avec votre propre identité : `SIGN_IDENTITY="Mon certificat" scripts/bundle.sh`.

## Contribuer

Les rapports de bogues, les traductions et les pull requests sont les bienvenus. Lisez d’abord [CONTRIBUTING.md](CONTRIBUTING.md). Les problèmes de sécurité passent par [SECURITY.md](SECURITY.md), pas par les issues publiques. Les notes de version sont dans [CHANGELOG.md](CHANGELOG.md).

## Licence

NativeShot est un logiciel libre sous [licence publique générale GNU v3.0](LICENSE). Vous pouvez l’utiliser, l’étudier, le modifier et le partager. Si vous distribuez une version modifiée, elle doit rester sous GPL-3.0, avec son code source disponible.
