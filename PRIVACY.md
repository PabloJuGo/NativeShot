# Privacidad

**English summary:** NativeShot works 100 % offline by default. It has no accounts, no telemetry and no uploads. Screenshots, recognized text and audio never leave your Mac. Everything is stored in `~/Library/Application Support/NativeShot/` (library) and in the folder you choose for saved files. The only network request the app can make is the optional, manual "Check for updates" button, which asks the project's GitHub releases feed for the latest version number and sends no identifier. The `nativeshot://` URL scheme is off by default. You can use a private session, exclude single captures from history, delete the text index and wipe the library at any time. Details below, in Spanish.

---

NativeShot se ha diseñado para que no tengas que confiar en nadie más que en tu propio Mac. Este documento describe qué datos toca la aplicación y qué decide el usuario.

## Qué no hace

- No hay cuentas, inicio de sesión ni identificadores de usuario.
- No hay telemetría, analítica ni informes de fallos automáticos.
- No sube capturas, grabaciones, texto reconocido ni audio a ningún servicio.
- No hace peticiones de red al arrancar ni en segundo plano.

## Qué guarda y dónde

| Dato | Dónde | Cómo borrarlo |
|---|---|---|
| Capturas, grabaciones, miniaturas y índice de búsqueda (SQLite) | `~/Library/Application Support/NativeShot/` | Biblioteca › Papelera › Vaciar, o borrar esa carpeta |
| Texto reconocido (OCR) para buscar | Mismo índice, opcional | Ajustes › Capturas › Historial (desactivar y borrar el índice de texto) |
| Etiquetas y favoritos | Mismo índice | Desde la biblioteca |
| Archivos que guardas o exportas | La carpeta que elijas (por defecto `~/Pictures/NativeShot`) | Como cualquier archivo |
| Preferencias | `UserDefaults` de la app | `defaults delete app.nativeshot.NativeShot` |
| Atajos globales | `UserDefaults` | Ajustes › Atajos |

Las capturas se exportan como píxeles aplanados: no llevan EXIF ni ubicación, salvo que lo pidas en el gestor de exportación (y entonces solo se añade el nombre de la app y la fecha).

## Control del usuario

- **Historial opcional**: puedes desactivarlo; las capturas pasan entonces por un archivo temporal.
- **Sesión privada**: mientras está activa no se guarda ni se indexa ninguna captura. No se conserva entre arranques.
- **Excluir una captura del historial** desde su miniatura.
- **Retención**: por número de elementos y por días en la papelera; «nunca borrar» es una opción.
- **Papelera interna** recuperable antes del borrado definitivo. El borrado elimina el archivo, la miniatura y el índice; no se promete borrado físico irrecuperable en SSD.
- **Diagnóstico local**: la exportación (Ayuda › Exportar diagnóstico) genera un JSON con versión, permisos y ajustes, sin capturas, nombres de archivo, texto reconocido ni rutas personales.
- **Copia de ajustes**: al exportarlos, las rutas personales se muestran para revisión y se omiten por defecto; al importar, cada valor se valida y los desconocidos se descartan.

## Permisos de macOS

- **Grabación de pantalla**: necesaria para capturar. Se pide cuando hace falta.
- **Micrófono y cámara**: solo si activas la narración o la cámara al grabar.
- NativeShot no tiene permisos de accesibilidad ni de monitorización de entrada; los atajos usan el registro global de teclas del sistema.

## Conexiones de red

Una sola, y solo cuando tú la pides: **Ajustes › General › Buscar actualizaciones…** consulta el feed de versiones de GitHub del repositorio configurado en la compilación (si no hay ninguno, muestra «no configurado» y no consulta nada). La petición no lleva identificadores ni datos tuyos. Si hay una versión nueva se abre su página en tu navegador; nunca se descarga ni instala nada automáticamente.

Los enlaces de códigos QR se muestran como texto y solo se abren si los confirmas.

## Acciones por URL (`nativeshot://`)

Desactivadas por defecto. Si las activas en Ajustes › Privacidad, solo funcionan las acciones que permitas una a una, cada petición pide confirmación (con «Cancelar» como opción por defecto) y ninguna URL puede capturar en silencio ni llevar parámetros. Importar un archivo de ajustes nunca activa esta función.

## Cambios en esta política

Cualquier cambio que afecte a qué datos salen del Mac se anotará en [`CHANGELOG.md`](CHANGELOG.md). Una integración con servicios en la nube, si llegara a existir, sería un módulo aparte y opcional, nunca una dependencia del núcleo.
