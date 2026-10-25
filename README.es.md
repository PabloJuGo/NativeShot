<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Icono de NativeShot">
</p>

<h1 align="center">NativeShot</h1>

<p align="center">
  <strong>Capturas y grabaciones de pantalla, nativas de macOS.</strong><br>
  Gratis, de código abierto y sin conexión. Sin cuentas, sin telemetría y sin subidas.
</p>

<p align="center">
  <a href="https://github.com/PabloJuGo/NativeShot/releases/latest"><img src="https://img.shields.io/github/v/release/PabloJuGo/NativeShot?label=descargar" alt="Última versión"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15 o posterior">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-universal-lightgrey" alt="Binario universal">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licencia-GPL--3.0-green" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <b>Español</b> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt.md">Português</a>
</p>

---

NativeShot vive en la barra de menús y sustituye a la herramienta de capturas del sistema por algo más rápido y completo. Captura cualquier zona, ventana o pantalla, anótala, extrae su texto, fíjala encima de tu trabajo o graba la pantalla con sonido y webcam. Todo ocurre en tu Mac.

<p align="center">
  <img src="docs/screenshots/editor.png" alt="Editor de imágenes" width="820">
</p>

## Funciones

**Captura**
- Zona, ventana (con o sin sombra), pantalla completa y **captura con scroll** (vertical, horizontal o directa a PDF).
- Lupa con coordenadas, pantalla congelada, proporciones y tamaños fijos, y ajuste de la selección antes de capturar.
- **Varias regiones** de una vez: mantén ⌘ al arrastrar y pulsa Retorno para terminar.
- Repetir la última zona o la última captura, temporizador y cursor opcional.
- Puede ocupar `⌘⇧5` con un asistente guiado, que nunca cambia los ajustes del sistema por ti.

**Después de capturar**
- Miniatura flotante para copiar, guardar, editar, fijar, compartir, arrastrar, eliminar, imprimir y más. Se maneja entera con el teclado.
- **Fija** cualquier captura encima de todas las ventanas, con zoom, opacidad y bloqueo para que los clics la atraviesen.
- **Reconocimiento de texto (OCR)** y lectura de QR y códigos de barras en el propio Mac. Los enlaces se muestran y nunca se abren sin preguntar.
- **Gestor de exportación**: plantilla de nombre, carpeta, PNG, JPEG, HEIC, TIFF o PDF, calidad, escala y eliminación de metadatos.

**Editor de imágenes**
- Flechas, líneas, formas, texto, resaltador, contadores numerados, foco, lupa, imágenes insertadas y capas.
- **Censura irreversible** (bloque, pixelado o desenfoque): al exportar se reescriben los píxeles, no solo se tapan.
- Fondos y marcos para presentar capturas, y proyectos `.nshot` editables.

**Grabación de pantalla**
- Pantalla, ventana o zona; audio del sistema y micrófono; webcam flotante; clics y teclas resaltados; cuenta atrás y pausa.
- MP4 o MOV, en H.264 o HEVC, y exportación a GIF.
- Editor de vídeo: recortar, cortar, zoom automático en los clics, seguimiento del cursor, silencios y subtítulos.

**Biblioteca**
- Historial local con búsqueda, también por el texto que aparece en tus capturas. Favoritos, etiquetas, papelera y reglas de retención.
- **Sesión privada**: mientras está activa no se guarda nada.

<table>
  <tr>
    <td><img src="docs/screenshots/ocr-light.png" alt="Ventana de texto reconocido"></td>
    <td><img src="docs/screenshots/recorder-dark.png" alt="Grabadora de pantalla"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/export-light.png" alt="Gestor de exportación"></td>
    <td><img src="docs/screenshots/onboarding-dark.png" alt="Ventana de bienvenida"></td>
  </tr>
</table>

## Instalación

1. Descarga **`NativeShot-<versión>.dmg`** de la [última versión](https://github.com/PabloJuGo/NativeShot/releases/latest).
2. Ábrelo y arrastra **NativeShot** a **Aplicaciones**.
3. Abre NativeShot. La primera vez, macOS dirá que no puede verificar al desarrollador, porque la app es gratuita y no está notarizada por Apple. Para abrirla de todos modos:
   - ve a **Ajustes del Sistema › Privacidad y seguridad**, baja hasta el aviso de NativeShot, pulsa **Abrir igualmente** y confirma;
   - o, en Terminal: `xattr -dr com.apple.quarantine /Applications/NativeShot.app`
4. Concede **Grabación de pantalla** cuando te lo pida (Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema). El micrófono y la cámara solo se piden si los activas para una grabación.

Requisitos: macOS 15 Sequoia o posterior, con Apple silicon o Intel. La interfaz está en español e inglés.

Para comprobar la descarga, usa el archivo `SHA256SUMS` que acompaña a cada versión: `shasum -a 256 -c SHA256SUMS`.

## Atajos por defecto

| Acción | Atajo |
|---|---|
| Selector de captura | `⌃⌥⌘5` (o `⌘⇧5` desde Ajustes › Atajos) |
| Zona | `⌃⌥⌘4` |
| Ventana | `⌃⌥⌘6` |
| Pantalla completa | `⌃⌥⌘3` |
| Texto (OCR) | `⌃⌥⌘2` |

Al seleccionar: `Espacio` alterna entre zona y ventana, arrastrar con `⌘` añade una región, las flechas ajustan la selección, `Retorno` confirma y `Esc` cancela. Todos los atajos se pueden cambiar en Ajustes.

## Privacidad

NativeShot no se conecta a internet. No tiene cuentas, analítica, informes de fallos ni nube. Las capturas, el texto reconocido y el audio nunca salen de tu Mac. La única petición de red posible es la comprobación de actualizaciones, y solo cuando pulsas **Buscar actualizaciones…**. Tu biblioteca está en `~/Library/Application Support/NativeShot/`. Más detalle en [PRIVACY.md](PRIVACY.md).

## Compilar desde el código

Solo necesitas las Command Line Tools de Xcode (Swift 6.2). No hace falta Xcode.

```sh
git clone https://github.com/PabloJuGo/NativeShot.git
cd NativeShot
scripts/test.sh             # ejecuta los tests
scripts/bundle.sh           # genera build/NativeShot.app
open build/NativeShot.app
```

`scripts/package.sh` genera el DMG y el ZIP. La firma ad hoc cambia en cada compilación, así que macOS puede volver a pedir el permiso de Grabación de pantalla tras recompilar. Para evitarlo, firma con tu propia identidad: `SIGN_IDENTITY="Mi certificado" scripts/bundle.sh`.

## Contribuir

Los informes de errores, las traducciones y los pull requests son bienvenidos. Lee antes [CONTRIBUTING.md](CONTRIBUTING.md). Los problemas de seguridad se comunican por la vía de [SECURITY.md](SECURITY.md), no en issues públicos. Las novedades de cada versión están en [CHANGELOG.md](CHANGELOG.md).

## Licencia

NativeShot es software libre bajo la [Licencia Pública General de GNU v3.0](LICENSE). Puedes usarlo, estudiarlo, modificarlo y compartirlo. Si distribuyes una versión modificada, debe seguir bajo GPL-3.0 y con su código fuente disponible.
