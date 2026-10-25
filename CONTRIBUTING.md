# Contribuir a NativeShot

**English summary:** NativeShot is a GPL-3.0, offline-first macOS 15+ screenshot and recording app written in Swift 6.2 (SwiftPM only, no Xcode project). Build with `swift build -c release`, run the tests with `scripts/test.sh` (all must pass), keep UI strings in Spanish with English translations in `Resources/en.lproj/Localizable.strings` (check with `scripts/check-strings.sh`), and never add telemetry, network calls on launch or cloud dependencies. By contributing you agree your work is licensed under GPL-3.0. Details below, in Spanish.

---

Gracias por querer ayudar. NativeShot es software libre (GPL-3.0), funciona sin conexión y no lleva telemetría; las contribuciones deben respetarlo.

## Preparar el entorno

- macOS 15 o posterior y las Command Line Tools de Xcode (Swift 6.2). No hace falta Xcode ni hay proyecto `.xcodeproj`: todo se construye con SwiftPM.
- `swift build -c release` compila la app; `scripts/bundle.sh` genera `build/NativeShot.app` (firma ad-hoc).
- `scripts/test.sh` ejecuta los tests (Swift Testing). Con solo las Command Line Tools usa este script y no `swift test` a secas.
- `swift build -c release -Xswiftc -DNATIVESHOT_QA` compila la variante con el arnés de autocomprobación (`scripts/selftest.sh`). Esa variante captura la pantalla y mueve el ratón: ejecútala solo en una sesión que no estés usando.

## Estructura

| Carpeta | Contenido |
|---|---|
| `Sources/NativeShotKit` | Lógica sin interfaz y probable sin ventanas: historial (SQLite), exportación, atajos, utilidades, editor, vídeo. |
| `Sources/NativeShot` | Aplicación: AppKit/SwiftUI, paneles, adaptadores de ScreenCaptureKit. |
| `Tests/NativeShotKitTests` | Tests de la lógica del Kit. |
| `Resources` | `Info.plist` y cadenas localizadas. |

Regla práctica: si algo se puede decidir sin una ventana (validar, analizar, migrar, ordenar), va en `NativeShotKit` con su test.

## Criterios para aceptar un cambio

1. **Tests**: `scripts/test.sh` pasa entero. La lógica nueva en el Kit trae tests; una migración de esquema trae un test que comprueba que no se pierden datos.
2. **Compilación limpia**: `swift build -c release` y la variante `-DNATIVESHOT_QA` sin errores ni avisos nuevos.
3. **Idioma**: el texto de la interfaz está en español (idioma de desarrollo) y cada cadena nueva tiene su traducción en `Resources/en.lproj/Localizable.strings`. `scripts/check-strings.sh` debe quedar sin pendientes propios (hay cuatro falsos positivos conocidos).
4. **Accesibilidad**: etiquetas de VoiceOver en controles sin texto, todo alcanzable con teclado, respeto de «reducir movimiento» y contraste alto.
5. **Privacidad** (ver [`PRIVACY.md`](PRIVACY.md)): nada de red al arrancar, nada de analítica, nada que envíe capturas, texto reconocido o audio fuera del Mac. Una acción que use la red debe ser explícita, del usuario y documentada.
6. **Concurrencia**: Swift 6 estricto. Evita `@unchecked Sendable` y `nonisolated(unsafe)` salvo justificación en un comentario.
7. **Paneles flotantes**: no uses un `NSHostingView` directamente como `contentView` de un panel sin borde dimensionado con `fittingSize`; usa `NSHostingView.fixed(_:)`. Para abrir Ajustes usa `AppController.openSettings()` (`showSettingsWindow:` no funciona desde macOS 14).
8. **Cambios pequeños**: un commit por cambio lógico, con mensaje que explique el porqué.

## Flujo de trabajo

1. Abre un issue si el cambio es grande o cambia el comportamiento visible.
2. Crea una rama desde `main`, haz commits pequeños y abre un pull request que explique qué cambia y cómo lo has probado (tests y, si toca la interfaz, qué comprobaste a mano).
3. Los cambios que tocan permisos de macOS, capturas o grabación se prueban en una Mac real; indica versión de macOS y tipo de pantalla.

## Licencia y autoría

El código se distribuye bajo GPL-3.0 (ver [`LICENSE`](LICENSE)). Al enviar una contribución aceptas que se publique bajo esa misma licencia. No incluyas código, iconos o fondos de terceros sin licencia compatible, ni copies estilos o recursos de otras aplicaciones.

## Seguridad

Los fallos de seguridad no se reportan en issues públicos: sigue [`SECURITY.md`](SECURITY.md).
