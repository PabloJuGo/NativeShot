# Registro de cambios

**English summary:** All notable changes are listed here, newest first, following "Keep a Changelog". `1.0.0` is the first public release: region/window/full-screen/scrolling capture, floating thumbnails and pins, on-device OCR/QR with a result window, a screen/video recorder and editor, an image editor, a local searchable library with tags, an export manager, global shortcuts, a private session mode and an optional, disabled-by-default `nativeshot://` scheme. Everything works offline; there is no telemetry. NativeShot is licensed under GPL-3.0. Details below, in Spanish.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y las versiones, [SemVer](https://semver.org/lang/es/).

## [1.0.0] - 2026-10-25

Primera versión pública. Funciona sin conexión, sin cuentas y sin telemetría. Licencia GPL-3.0.

### Captura

- Región, ventana y pantalla completa con selector, temporizador, cursor opcional y sombra de ventana.
- Captura con scroll vertical y horizontal (también a PDF), repetir la última región y **repetir la última captura** (misma región, ventana o pantalla).
- Lupa con coordenadas, pantalla congelada, proporciones y tamaños fijos, ajuste de la región antes de capturar y **varias regiones** con ⌘ (una composición o una captura por región).
- Atajos globales configurables, con asistente para sustituir `⌘⇧5` sin tocar los ajustes del sistema.

### Miniatura rápida e imágenes fijadas

- Miniaturas apiladas con copiar, guardar, editar, fijar, compartir, copiar ruta, mostrar en Finder y eliminar; menú de **más acciones** (exportar, imprimir, abrir con, reconocer texto, repetir, excluir del historial).
- Navegación por teclado entre miniaturas (flechas), ⌘C, ⌘S, ⌘E, ⌘P, ⌘R y Esc.
- Imágenes fijadas con zoom, opacidad, desplazamiento con flechas, **bloqueo de clics** (se desbloquea siempre desde el menú de la barra) y posición recordada por pantalla.

### OCR y códigos

- Reconocimiento en el dispositivo (Vision) y lectura de QR/códigos de barras.
- **Ventana de resultado**: imagen con las líneas reconocidas seleccionables, elección de idioma, copiar selección o todo; los enlaces de códigos se muestran como texto y piden confirmación antes de abrirse. Ajuste para elegir entre la ventana y el copiado directo.

### Biblioteca e historial

- Historial local en SQLite con búsqueda de texto completo, favoritos, papelera interna y retención configurable.
- **Esquema v3**: etiquetas propias con búsqueda y filtro, y filtro por aplicación de origen. La migración desde v1 y v2 no pierde datos.
- **Selección múltiple y acciones en bloque**: papelera, favorito, etiquetas y exportación.
- **Sesión privada** (no guarda nada mientras está activa) y exclusión de capturas concretas del historial.

### Exportación

- **Gestor de exportación**: nombre con plantilla, carpeta, formato (PNG, JPEG, HEIC si el Mac lo admite), calidad, escala y metadatos, con estados de progreso, éxito y error.
- Imprimir y abrir con una aplicación instalada.

### Editor de imágenes

- Flechas, formas, texto, resaltador, contadores, lupa, recorte, cuentagotas, imágenes insertadas y capas con bloqueo y alineación.
- **Censura irreversible** (bloque, pixelado y desenfoque): los píxeles se reescriben al exportar.
- Fondos y marcos para presentar capturas; exportación a PNG, JPEG, HEIC, TIFF y PDF; imprimir con ⌘P; proyectos `.nshot` editables.

### Grabación y editor de vídeo

- Pantalla, ventana o región; audio del sistema y micrófono (con elección de dispositivo); webcam flotante; clics y teclas resaltados; cuenta atrás; pausa; MP4 o MOV en H.264 o HEVC.
- Editor de vídeo con recorte, cortes, zoom automático por clics, seguimiento del cursor, silencios, subtítulos y exportación a GIF.

### Utilidades

- Atajos para fijar el portapapeles, abrir la biblioteca, abrir ajustes, sesión privada y cerrar imágenes fijadas (sin combinación por defecto).
- **Exportar e importar ajustes** (JSON) con revisión de datos personales al exportar y validación al importar.
- **Buscar actualizaciones** manual: consulta las versiones del repositorio de GitHub solo al pulsar el botón.
- Acciones por URL `nativeshot://`, **desactivadas por defecto**, con lista de acciones permitidas y confirmación en cada uso; nunca capturan en silencio.
- Diagnóstico local exportable sin capturas ni rutas personales.

### Documentación

- Añadidos `CONTRIBUTING.md`, `PRIVACY.md`, `SECURITY.md` y este registro.

### Limitaciones conocidas

- La firma es ad hoc y la app no está notarizada: la primera vez hay que abrirla desde Ajustes del Sistema › Privacidad y seguridad › «Abrir igualmente». Al actualizar, macOS puede volver a pedir el permiso de Grabación de pantalla.
- Sin cifrado de la biblioteca ni integración en la nube, por decisión de diseño de esta edición.
- De las imágenes fijadas solo se recuerda la última posición por pantalla; no se reabren al reiniciar la app.
