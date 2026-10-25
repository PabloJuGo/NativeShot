# Checklist de pruebas manuales — NativeShot

Pruebas que no pueden automatizarse con SwiftPM y Command Line Tools: permisos reales, atajos del sistema, arrastrar y pegar entre apps, multimonitor y grabación. Ejecútala en un Mac real con la build de release.

**Tiempo:** unos 40 minutos para la preparación y los bloques 1 y 2, más 5–10 minutos del bloque 3. Ordenada por prioridad: el bloque 1 contiene los gates de S1 y S2 y los bloqueos de publicación. Si el tiempo se acaba, el bloque 1 es obligatorio y el resto puede marcarse como «no ejecutado».

Marca cada caso con `[x]` si pasa, `[!]` si falla (describe el fallo en el reporte) o `[-]` si no aplica o no se ha podido ejecutar (anota el motivo).

## Preparación (5 min)

- [ ] **P-1** Compila y abre la app:
  ```
  scripts/bundle.sh release && open build/NativeShot.app
  ```
  Esperado: aparece el icono en la barra de menús. La firma ad-hoc hace que macOS pida de nuevo el permiso de grabación tras cada recompilación; es normal.
- [ ] **P-2** Anota el entorno: versión de macOS (menú Apple › Acerca de este Mac), modelo, número de monitores, escala de cada uno (Ajustes › Pantallas), idioma del sistema y el commit o build que pruebas.
- [ ] **P-3** Prepara material neutro: una página de texto en español con acentos (ñ, á, é, ü), una página de Safari con artículo largo, un PDF de varias páginas, una lista larga (Finder en vista de lista, con 200 o más elementos) y un código QR generado con una URL de prueba. No uses datos personales reales.
- [ ] **P-4** Abre Ajustes del Sistema › Privacidad y seguridad y deja a mano los paneles de Grabación de pantalla, Accesibilidad y Monitorización de entrada.

---

## Bloque 1 — P0: gates S1/S2 y bloqueos de publicación (≈20 min)

### 1.1 Permiso de grabación de pantalla (TCC)

- [ ] **TCC-1** Sin permiso de grabación de pantalla, pulsa `⌘⇧5` (o «Capturar región» en el menú).
  Esperado: NativeShot explica que falta el permiso («Falta el permiso de grabación de pantalla»), ofrece un camino para concederlo y no se cierra ni deja la interfaz bloqueada.
- [ ] **TCC-2** Concede el permiso en Ajustes del Sistema. Si macOS pide reiniciar la app, reiníciala. Haz una captura de región.
  Esperado: la captura funciona sin reinicios adicionales salvo los que pida macOS.
- [ ] **TCC-3** Con la app abierta, retira el permiso en Ajustes del Sistema y vuelve a capturar.
  Esperado: aviso claro, sin crash ni captura vacía o negra.

### 1.2 Captura en 1 y 2 monitores

- [ ] **CAP-1** Región en el monitor principal. Arrastra y suelta en la esquina. Comprueba la imagen en la miniatura.
  Esperado: la imagen tiene exactamente la región elegida (en Retina, el doble de píxeles que puntos); Esc durante la selección cancela sin guardar nada.
- [ ] **CAP-2** Región en el monitor secundario, con distinta escala si la hay.
  Esperado: el contenido es el del monitor donde arrastraste, sin desplazamiento ni corte.
- [ ] **CAP-3** Ventana: pasa el cursor sobre dos ventanas (una de ellas en el monitor secundario) y haz clic. Prueba con «Sombra en capturas de ventana» activada y desactivada.
  Esperado: la ventana bajo el cursor se resalta y se captura entera; con la sombra activa aparece el margen de sombra, y con ella desactivada no.
- [ ] **CAP-4** Pantalla completa de cada monitor (clic en el monitor, o Return).
  Esperado: el monitor elegido, no el otro; sin mezclar resoluciones.
- [ ] **CAP-5** Región que cruza los dos monitores.
  Esperado: no hay crash ni imagen corrupta; la captura se limita a un monitor o se explica el motivo.
- [ ] **CAP-6** Cambia la resolución del monitor (Ajustes › Pantallas) entre elegir la región y el instante de capturar, o desconecta el monitor secundario durante la selección.
  Esperado: captura correcta o error explicado; nunca una imagen de otro monitor presentada como si fuera el elegido.

### 1.3 Captura → pegar en 3 apps (gate S1)

- [ ] **S1-1** Captura una región. En la miniatura pulsa «Copiar». Pega (`⌘V`) en **Notas**.
  Esperado: la imagen aparece completa y nítida.
- [ ] **S1-2** Captura otra región. Pega en un correo nuevo de **Mail**.
  Esperado: la imagen se inserta en el cuerpo del mensaje.
- [ ] **S1-3** Captura y pega en una app de tu elección distinta a las anteriores (por ejemplo TextEdit, Pages o un campo de texto de Safari con imagen permitida).
  Esperado: se pega la imagen, no un nombre de archivo ni texto vacío.
- [ ] **S1-4** Copia con «Copiar y guardar» (o con la opción de guardar tras capturar) y comprueba que el archivo existe en la carpeta de guardado.
  Esperado: el PNG se abre en Vista Previa; el nombre sigue la plantilla y no sobrescribe archivos existentes (una segunda captura genera «… 2»).

### 1.4 Atajo ⌘⇧5 y atajos globales (gate S2: HOTKEY-A a E)

Precondición: el asistente de Ajustes › Atajos ya estaba completado, con el atajo de Apple desactivado en Ajustes del Sistema › Teclado › Atajos de teclado (o «Funciones rápidas de teclado», según la versión) › Capturas de pantalla.

- [ ] **HOTKEY-A** Desde **Finder** pulsa `⌘⇧5`. Repite desde **Safari**.
  Esperado: abre el selector de NativeShot y no la barra de captura de Apple.
- [ ] **HOTKEY-B** Vuelve a activar en Ajustes del Sistema la opción de captura de Apple (⇧⌘5) y regresa a Ajustes de NativeShot.
  Esperado: el estado muestra «Atajo del sistema posiblemente activo» o «Registrado, pero el atajo de Apple parece seguir activo», con los pasos para desactivarlo. No promete que haya sustitución. El texto dice que ⇧⌘3 y ⇧⌘4 no se tocan.
- [ ] **HOTKEY-C** Pulsa «Restaurar macOS» en Ajustes de NativeShot.
  Esperado: NativeShot deja de interceptar ⌘⇧5, y la app explica cómo volver a activar el atajo de Apple. Comprueba que tras desactivarlo, Apple sigue sin reaparecer solo.
- [ ] **HOTKEY-D** Cierra y vuelve a abrir NativeShot; pulsa `⌘⇧5`. Si activaste «Abrir al iniciar sesión», cierra la sesión, vuelve a entrar y repite. (Esta parte se hace al final, porque obliga a cerrar la sesión.)
  Esperado: el atajo funciona tras reabrir y tras el inicio de sesión.
- [ ] **HOTKEY-E** Revisa Ajustes del Sistema › Privacidad y seguridad › Accesibilidad y Monitorización de entrada.
  Esperado: NativeShot no aparece en ninguna de las dos listas por el uso normal de los atajos, y no se ha pedido ningún permiso al pulsarlos.
- [ ] **HOTKEY-X** En Ajustes › Atajos graba una combinación que ya usa otra app, o una que macOS rechace.
  Esperado: mensaje de error útil («macOS no ha permitido registrar el atajo…») que sugiere otra combinación, como `⌃⌥⌘5`, y el atajo anterior sigue funcionando.

### 1.5 Miniatura rápida

- [ ] **QAO-1** Captura y arrastra la miniatura a **Finder** (a una carpeta del escritorio).
  Esperado: se crea un PNG con la captura.
- [ ] **QAO-2** Arrastra la miniatura al cuerpo de un correo nuevo en **Mail**, y después a un formulario de subida de archivos en el **navegador** (el selector de archivos o un área de arrastre).
  Esperado: el archivo se adjunta o acepta; el formulario no queda en blanco.
- [ ] **QAO-3** Pulsa «Guardar» en la miniatura, y después «Mostrar en Finder».
  Esperado: la carpeta se abre con el archivo seleccionado.
- [ ] **QAO-4** Pulsa «Eliminar» en la miniatura de una captura de prueba.
  Esperado: la acción pide confirmación o manda la captura a la papelera. **Hallazgo conocido: hoy elimina el original sin confirmación; anota el resultado tal como ocurra.**
- [ ] **QAO-5** Haz tres capturas seguidas. Usa «Restaurar última miniatura» en el menú.
  Esperado: las miniaturas se apilan sin tapar la barra de menús ni salir de la pantalla; la última se restaura.

---

## Bloque 2 — P1: funciones principales (≈15 min)

Sugerencia: lanza primero el caso **REC-5** (10 minutos) y haz el resto de este bloque mientras graba.

### 2.1 Pines

- [ ] **PIN-1** Fija una captura desde la miniatura («Fijar»), otra desde las recientes del menú y otra desde el portapapeles («Fijar imagen del portapapeles», con una imagen copiada antes).
  Esperado: las tres imágenes quedan siempre visibles encima de las demás ventanas.
- [ ] **PIN-2** Arrastra una imagen fijada, haz zoom con `⌘+` y `⌘−` (y con pellizco en el trackpad), cambia la opacidad desde el menú contextual.
  Esperado: se mueve, cambia de tamaño y de opacidad sin saltos.
- [ ] **PIN-3** Cierra con `Esc` y con `⌘W`; después fija dos imágenes y usa «Cerrar imágenes fijadas».
  Esperado: se cierran todas sin afectar a la app que estaba debajo.

### 2.2 OCR y QR

- [ ] **OCR-1** Captura («Capturar texto (OCR)») un texto en español con ñ, tildes y mayúsculas. Pega en TextEdit.
  Esperado: el texto se copia con sus acentos; el toast indica el número de caracteres.
- [ ] **OCR-2** Repite con texto claro sobre fondo oscuro, y con una línea de texto vertical si tienes una.
  Esperado: el texto legible se copia; si no se reconoce, el toast lo dice («No se ha encontrado texto») en lugar de copiar basura en silencio.
- [ ] **QR-1** Captura («Capturar texto (OCR)») un código QR que contiene una URL de prueba. Antes de pegar, abre Safari en una pestaña nueva y no hagas nada más.
  Esperado: la URL se copia como texto (toast «Código copiado»); **Safari no se abre ni navega sola.**

### 2.3 Biblioteca

- [ ] **LIB-1** Abre «Abrir biblioteca…». Busca por nombre de la app origen y por una palabra que aparezca en el texto OCR de OCR-1.
  Esperado: aparecen las capturas correspondientes; una búsqueda sin resultados muestra un estado vacío claro.
- [ ] **LIB-2** Marca una captura como favorita (tecla `F` o «Añadir a favoritos») y activa «Solo favoritos».
  Esperado: el filtro muestra solo las favoritas.
- [ ] **LIB-3** Envía una captura a la papelera (⌫) y ábrela en la vista de papelera. Restaura una.
  Esperado: la captura vuelve a la biblioteca y los archivos siguen en su sitio.
- [ ] **LIB-4** En la papelera pulsa «Eliminar definitivamente…» y «Vaciar papelera…».
  Esperado: ambas acciones piden confirmación y, al confirmar, desaparecen de la lista; los archivos se borran.

### 2.4 Editor y redacción

- [ ] **IMG-1** Abre una captura con texto de prueba tipo contraseña («clave-123456») con «Editar» desde la miniatura. Anota una flecha, un rectángulo y un contador. Deshaz y rehaz con `⌘Z` y `⇧⌘Z`.
  Esperado: las anotaciones se dibujan donde las colocas; undo y redo restauran el estado exacto.
- [ ] **RED-1** Sobre la contraseña de prueba aplica «Censurar con bloque», y en otra captura «Pixelar» y «Desenfocar». Exporta a PNG y a JPEG.
  Esperado: el archivo exportado no muestra el texto cubierto.
- [ ] **RED-2** Abre el PNG exportado en Vista Previa y amplía al máximo la zona censurada. Intenta leer el texto.
  Esperado: no se puede recuperar el texto original (ni por contraste, ni con «Herramientas › Ajustar»).
- [ ] **RED-3** Guarda el trabajo con «Guardar proyecto» (`.nshot`).
  Esperado: la app avisa de que el proyecto conserva el original (texto «El proyecto .nshot conserva el original»). Anota si no lo avisa; es un hallazgo de privacidad.

### 2.5 Captura con scroll

- [ ] **SCR-1** Safari, artículo largo. Elige «Captura con scroll», selecciona la zona del texto y desplázate despacio con el trackpad hasta el final. Pulsa «Terminar».
  Esperado: el resultado no duplica párrafos ni repite la cabecera fija; si la unión no es fiable, la app lo indica en lugar de entregar un resultado con uniones erróneas.
- [ ] **SCR-2** Haz scroll hacia abajo y luego hacia arriba (hacia atrás) a mitad de la captura, y termina.
  Esperado: el contenido no aparece duplicado.
- [ ] **SCR-3** PDF de varias páginas en Vista Previa en modo de desplazamiento continuo.
  Esperado: el resultado sigue el orden de las páginas; ante una unión dudosa, la app avisa.
- [ ] **SCR-4** Lista larga virtualizada (Finder en vista de lista con 200 elementos, o la lista de Mail).
  Esperado: captura correcta o error explicado. **Nunca** un montaje corrupto presentado como válido.
- [ ] **SCR-5** Inicia una captura con scroll y pulsa Cancelar durante el desplazamiento.
  Esperado: no se guarda nada y la app vuelve a su estado normal; el siguiente atajo funciona.

### 2.6 Grabación de pantalla

- [ ] **REC-1** Con micrófono concedido, graba 30 s con «Audio del sistema» y «Micrófono» activados. Habla y reproduce un sonido del sistema. Cuenta atrás de 3 s al empezar.
  Esperado: al reproducir en QuickTime se oyen la voz y el sonido del sistema a la vez y sincronizados (da una palmada y compruébalo).
- [ ] **REC-2** Pausa a los 10 s y reanuda a los 20 s; detén a los 30 s.
  Esperado: en el vídeo no hay un hueco de 10 s congelado; la duración es de unos 20 s; el archivo se reproduce.
- [ ] **REC-3** Mientras grabas, comprueba que la barra de control de NativeShot (botones Pausar, Detener) **no aparece en el vídeo** reproducido.
  Esperado: la barra no aparece en el vídeo.
- [ ] **REC-4** Deniega el micrófono en Ajustes del Sistema y graba con él marcado.
  Esperado: mensaje «Sin acceso al micrófono: se grabará sin él», sin crash; el vídeo se genera con audio del sistema o mudo.
- [ ] **REC-5** Graba 10 minutos a 1080p30 con audio del sistema y micrófono, mientras haces otras cosas normales. Vigila CPU y memoria en Monitor de Actividad y revisa si la app informó de fotogramas perdidos.
  Esperado: el archivo se genera completo y reproducible, la sincronía se mantiene, la memoria no crece sin parar y no hay pérdidas de fotogramas notables. Anota los fotogramas perdidos si la app los informa.
- [ ] **REC-6** Detén una grabación con el micrófono desconectado a mitad (AirPods o un USB) y vuelve a grabar después de reconectar.
  Esperado: la grabación no se rompe de forma silenciosa; si el micrófono falla, se indica al usuario.

---

## Bloque 3 — P2: casos extremos (≈5-10 min)

Solo si queda tiempo. Anota «no ejecutado» con el motivo cuando un caso no se pueda reproducir.

- [ ] **EXT-1** Pantalla completa de una app (Safari en pantalla completa) y un espacio de Mission Control distinto: captura la ventana y la región.
  Esperado: captura correcta o explicación; nunca una captura del escritorio de otro espacio.
- [ ] **EXT-2** Stage Manager activado: captura de una ventana que está en un grupo lateral.
  Esperado: se captura la ventana con su contenido, o un error explicado.
- [ ] **EXT-3** Modo oscuro y claro: captura de la miniatura y de la biblioteca en ambos.
  Esperado: texto legible, sin contraste roto.
- [ ] **EXT-4** VoiceOver (⌘F5) sobre la miniatura y la biblioteca.
  Esperado: los botones tienen etiqueta y se pueden activar.
- [ ] **EXT-5** Reducir movimiento (Ajustes › Accesibilidad › Pantalla): abre el selector y las miniaturas.
  Esperado: las animaciones se reducen y la interfaz sigue usable.
- [ ] **EXT-6** Equipo suspendido durante una grabación (cierra la tapa 10 s y vuelve a abrirla).
  Esperado: al despertar, la grabación termina con un error explicado y el archivo previo sigue siendo reproducible.
- [ ] **EXT-7** Importa un proyecto `.nshot` manipulado (copia un proyecto y cambia a mano `width` en `manifest.json`). Si la vía de apertura está disponible.
  Esperado: se rechaza con un error controlado; la app no se cierra. Si no hay vía de apertura en la interfaz, marca como no ejecutado.
- [ ] **EXT-8** Desconecta el monitor secundario mientras la miniatura o el editor están abiertos en él.
  Esperado: la ventana se recoloca en un monitor visible; sin ventanas perdidas fuera de pantalla.

---

## Cómo reportar

Un reporte útil tiene estos datos. Sin ellos no se puede reproducir.

1. **Caso:** ID de la checklist (por ejemplo `HOTKEY-B`) y resultado (`[!]` o `[-]`).
2. **Entorno:** versión de macOS, modelo del equipo, número y escala de los monitores, commit o build de NativeShot.
3. **Pasos reales:** lo que hiciste, en orden, y el resultado observado frente al esperado.
4. **Frecuencia:** si pasa siempre, a veces, o solo la primera vez tras el permiso.
5. **Registro:** en Terminal, `log show --last 15m --predicate 'process == "NativeShot"' > nativeshot.log`. Revísalo antes de adjuntarlo: puede contener nombres de archivo o títulos de ventana.
6. **Capturas de pantalla del reporte:** solo de la interfaz de NativeShot sobre material neutro (la página de prueba, el PDF de prueba, texto de prueba). **Nunca adjuntes capturas privadas, ni de tus cuentas, ni de tu escritorio.** Si el fallo solo se ve con datos reales, describe el tipo de contenido sin mostrarlo.
7. **Vídeos y PDFs:** solo los que hayas generado con contenido de prueba. Para perf, un trace de Instruments solo si lo has revisado: suele incluir títulos de ventanas y rutas.

Para hallazgos de rendimiento (B-02, B-03, apertura del editor), graba un trace con Instruments usando la plantilla «os_signpost», con los intervalos `shortcut-to-overlay`, `selection-to-thumbnail` y `editor-open` (subsistema `app.nativeshot.NativeShot`, categoría `Rendimiento`), y anota el equipo y las condiciones de energía (enchufado, térmico).
