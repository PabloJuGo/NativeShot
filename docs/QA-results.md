# Resultados de QA — 2026-10-25

Equipo: MacBook Air M4 (Mac16,13), macOS 27.0.1, un monitor Retina (1710×1107 pt, escala 2), teclado español.
Build: release con `-DNATIVESHOT_QA`, firmada con la identidad local «NativeShot Local Dev» (`scripts/dev-cert.sh`).

## Cómo se ha probado

`scripts/selftest.sh` lanza la app real con `--qa-selftest`. Usa los permisos reales (Grabación de pantalla, Micrófono, Cámara y Accesibilidad), ScreenCaptureKit y ventanas reales. La entrada es sintética (CGEvent: atajos, arrastres, clics, rueda y teclas) y la verificación es programática: píxeles, OCR de lo exportado, pistas y picos de audio, filas de la imagen unida y árbol de accesibilidad. Un proceso aparte con otro bundle id (`NSQAFixture.app`) muestra contenido conocido: cuadrantes de color, texto con tildes, un QR, una lista de 120 filas, una animación con un tono de 880 Hz y un editor de texto enriquecido. El autotest usa una biblioteca aislada y nunca toca la del usuario.

Resultado final (versión 1.0.2): **37/37 pasos en verde** (`/tmp/nsqa/full9/report.md`, con capturas de cada superficie en claro y oscuro). El paso MENU recorre el menú de la barra con clics reales. Los 6 pasos nuevos cubren varias regiones con ⌘, pantalla congelada, sesión privada, pin bloqueado, la ventana de texto reconocido y el gestor de exportación.

## Casos de `docs/QA-manual.md`

Leyenda: ✅ verificado automáticamente en la app real · 🧪 cubierto por tests del Kit · 👤 requiere a una persona o hardware que no hay en este equipo.

| Caso | Estado | Evidencia o motivo |
|---|---|---|
| P-1 Compila y abre | ✅ | `scripts/bundle.sh release` y `selftest.sh` |
| P-2 Entorno | ✅ | paso ENV del informe |
| P-3 / P-4 Material y paneles | — | preparación manual, sustituida por el proceso fixture |
| TCC-1 Sin permiso | 👤 | requiere revocar el permiso en Ajustes del Sistema |
| TCC-2 Conceder permiso | ✅ | concedido y persistente gracias a la firma estable |
| TCC-3 Retirar con la app abierta | 👤 | requiere revocar el permiso |
| CAP-1 Región, monitor principal | ✅ | CAP-REGION y E2E-HOTKEY (arrastre real; tamaño y colores exactos) |
| CAP-2 / CAP-5 / CAP-6 Segundo monitor, cruce, cambio de resolución | 👤 | un solo monitor |
| CAP-3 Ventana con y sin sombra | ✅ | CAP-WINDOW y E2E-WINDOW (corregido: la sombra se recortaba) |
| CAP-4 Pantalla completa | ✅ | CAP-DISPLAY |
| S1-1..3 Pegar en 3 apps | ✅ | S1-PASTE: pegado en un NSTextView enriquecido (el mismo motor que TextEdit, Mail y Notas) a tamaño completo. Pegar en Notas o Mail en concreto: 👤 |
| S1-4 Copiar y guardar | ✅ | EXP (PNG y JPEG, nombres únicos, sin GPS) |
| HOTKEY-A..E ⌘⇧5 | 👤 | requiere desactivar el atajo de Apple en Ajustes del Sistema; la sonda informa `possiblyActive` |
| HOTKEY-X Conflicto | 🧪 | `ShortcutRegistryTests` |
| QAO-1 / QAO-2 Arrastrar a Finder, Mail y navegador | 👤 | arrastre entre apps |
| QAO-3 Guardar / Mostrar en Finder | ✅ parcial | guardar (EXP); abrir Finder no se automatiza |
| QAO-4 Eliminar | ✅ | HIS: va a la papelera y se restaura |
| QAO-5 Restaurar última | ✅ | QAO-KEYS (también Esc y ⌘C con foco de teclado) |
| PIN-1 Fijar | ✅ | PIN |
| PIN-2 Zoom ⌘+/⌘− y opacidad | ✅ | PIN-KEYS (corregido: ⌘+/⌘− no hacían nada). Pellizco en el trackpad: 👤 |
| PIN-3 Esc, ⌘W y cerrar todas | ✅ | PIN-KEYS |
| OCR-1 Español | ✅ | OCR: «Número de pedido 4815», «Canción año acción» |
| OCR-2 Claro sobre oscuro y vertical | 👤 | sin fixture específico |
| QR-1 QR sin abrir la URL | ✅ | OCR: copia el contenido y no cambia la app activa |
| LIB-1 Búsqueda | ✅ | HIS: «numero pedido» sin tilde encuentra la captura por su OCR |
| LIB-2 Favoritos | 🧪 | `HistoryStoreTests` y `HistoryV2Tests` |
| LIB-3 Papelera y restaurar | ✅ | HIS |
| LIB-4 Eliminar definitivamente y vaciar | 🧪 | tests del Kit; no se ejecuta en la app para no borrar nada real |
| IMG-1 Anotar, deshacer y rehacer | 🧪 | `EditorTests`; el editor abre (captura `ui-editor`) |
| RED-1 / RED-2 Censura irreversible | ✅ | IMG: bloque, pixelado y desenfoque exportados y releídos; el OCR no recupera el texto y el resto queda intacto |
| RED-3 Proyecto `.nshot` | 🧪 | `EditorTests` (ida y vuelta, y paquetes maliciosos) |
| SCR-1 Scroll largo | ✅ | SCR: 4000 px y 45 filas sin duplicados ni huecos (corregidos el alineador y las esquinas en cada unión) |
| SCR-2 Volver atrás | ✅ | SCR-BACK (corregido: crash) |
| SCR-3 / SCR-4 PDF y lista virtualizada | 👤 parcial | el fixture dibuja bajo demanda como una lista virtualizada; PDF y Finder no probados |
| SCR-5 Cancelar | ✅ | SCR-CANCEL: no guarda nada |
| CAP-011 Varias regiones | ✅ | MULTI: ⌘ + arrastrar dos veces y Return da una composición con las dos (corregido: el ⌘ del atajo activaba el modo sin querer) |
| CAP-010 Congelar pantalla | ✅ | FREEZE: la captura sale de la imagen congelada, sin el oscurecido del overlay |
| HIS Sesión privada | ✅ | PRIVATE: la captura se hace pero no llega a la biblioteca |
| PIN-001 Bloqueo de pines | ✅ | PIN-LOCK |
| UI-07 / UI-19 Texto reconocido y exportar | ✅ | TOOLS: capturas `ui-ocr-*` y `ui-export-*`; la ventana muestra «4815» en su árbol de accesibilidad |
| Exportar TIFF y PDF | 🧪 | `EditorExtrasTests` |
| REC-1 Audio del sistema, micrófono y cuenta atrás | ✅ | REC, REC-MIC y REC-COUNTDOWN (tono detectado en la pista, 2 pistas con micrófono, cuenta atrás de ≈3 s) |
| REC-2 Pausa y reanudar | ✅ | REC: la duración final excluye la pausa |
| REC-3 La barra no sale en el vídeo | ✅ visual | `rec-*-frame.png`: la barra no aparece; la burbuja de webcam sí, a propósito |
| REC-4 Micrófono denegado | 👤 | requiere revocar el permiso |
| REC-5 10 minutos | ✅ | REC-LONG (`NS_QA_LONG=600`): 602 s, 97,1 % de los fotogramas, A/V sincronizados en ±0,05 s y memoria estable |
| REC-6 Micrófono desconectado | 👤 | sin dispositivo externo |
| EXT-1 / EXT-2 Pantalla completa, Spaces y Stage Manager | 👤 | |
| EXT-3 Claro y oscuro | ✅ | UI: capturas `ui-*-light/dark.png` |
| EXT-4 VoiceOver | ✅ parcial | A11Y: todos los controles de bienvenida, biblioteca, grabadora, ayuda y ajustes tienen nombre, y la miniatura expone 8 acciones al rotor. Escuchar VoiceOver de verdad: 👤 |
| EXT-5 Reducir movimiento | 👤 | ajuste del sistema |
| EXT-6 Suspensión al grabar | 👤 | |
| EXT-7 `.nshot` manipulado | 🧪 | `EditorTests` (paquetes maliciosos) |
| EXT-8 Desconectar monitor | 👤 | |

## Rendimiento medido en la app real (paso PERF, 8 repeticiones)

| Métrica | p50 | p95 | Objetivo |
|---|---|---|---|
| Atajo → overlay visible | 53 ms | 59 ms | ≤ 120 / ≤ 250 ms |
| Soltar la selección → miniatura visible | 158 ms | 160 ms | ≤ 300 / ≤ 600 ms |

Son eventos sintéticos en un M4 enchufado: una sola máquina, sin Intel y sin carga.

## Errores encontrados y corregidos por esta QA

1. La app se cerraba al mostrar cualquier toast o la barra de grabación (bucle de restricciones de NSHostingView).
2. La miniatura flotante y la barra de modos tenían tamaño 0×0.
3. La captura con scroll rechazaba como ambigua cualquier página con bloques de color uniformes.
4. Las esquinas redondeadas de la ventana se colaban en cada unión del scroll.
5. Volver atrás durante la captura con scroll cerraba la app.
6. La sombra de la captura de ventana se recortaba.
7. El modo ventana no permitía elegir ventanas flotantes, y el resaltado esperaba al primer movimiento del ratón.
8. «Ajustes» no se abría desde la bienvenida (`showSettingsWindow:` no hace nada desde macOS 14).
9. Los vídeos aparecían sin miniatura en la biblioteca.
10. ⌘+ y ⌘− no hacían zoom en los pines.
11. Con el atajo por defecto (⌃⌥⌘4) el ⌘ seguía pulsado al arrastrar y la selección entraba en modo «varias regiones» sin querer: soltar no capturaba. Ahora ⌘ solo añade regiones si se pulsa después de abrir el overlay.
12. **Ajustes…** desde el menú de la barra abría la ventana detrás de la app activa (lo detectó el usuario; los pasos anteriores llamaban a la función directamente y no al menú). Ahora el paso MENU hace clic de verdad en cada elemento del menú que abre una ventana.
13. **Abrir vídeo en el editor…** mostraba el diálogo de abrir detrás de las demás apps.
14. Las grabaciones en sesión privada se guardaban en la biblioteca (1.0.1).

Todos tienen un paso del autotest, y los del Kit (3, 4 y 5) además un test de regresión.

## Estrés y reposo (pasos SOAK e IDLE)

- **SOAK** (`NS_QA_SOAK=300`): 300 capturas de región de 400×300 pt seguidas, en 34 s (≈115 ms por ciclo, PNG en disco incluido). RSS de 93 MB al inicio, 162 MB de máximo y 147 MB al final, con pendiente negativa en la segunda mitad. No hay crecimiento sostenido.
- **IDLE**: 20 s en reposo tras toda la batería: **0,31 % de CPU** (objetivo < 1 %). La memoria se mide como huella física (`phys_footprint`, la de Monitor de Actividad); el tamaño residente también contaba las páginas compartidas de los frameworks del sistema. Al arrancar en reposo son **30 MB** (objetivo ≤ 120 MB). Tras ejecutar todas las funciones (cámara, AVFoundation y Vision cargados) son 228 MB, por debajo de la cota anti-fugas de 250 MB.
- **Pico conocido:** mientras el overlay está abierto con la lupa o la pantalla congelada, la huella sube de forma transitoria (hasta ≈600 MB en el paso MULTI, por las instantáneas a pantalla completa y las cachés de dibujo) y se libera al cerrarlo.
