# Política de seguridad

**English summary:** Please report vulnerabilities privately through GitHub's "Report a vulnerability" (private security advisory) on the repository, not in public issues. Include the version, macOS version, steps to reproduce and impact. We aim to acknowledge reports within 7 days and to ship a fix or mitigation for confirmed issues as soon as practical, crediting reporters who wish it. Only the latest release and `main` are supported. Details below, in Spanish.

---

## Versiones con soporte

Se corrigen los fallos de seguridad de la última versión publicada y de la rama `main`. Las versiones candidatas (`-rc`) reciben correcciones hasta que sale la versión final.

## Cómo informar de una vulnerabilidad

No abras un issue público. Usa **Security › Report a vulnerability** (aviso de seguridad privado de GitHub) en el repositorio. Incluye:

- versión de NativeShot y de macOS;
- pasos para reproducirlo y, si puedes, una prueba de concepto mínima;
- qué impacto crees que tiene (qué datos o acciones quedan expuestos).

Intentamos acusar recibo en 7 días y publicar una corrección o mitigación en cuanto se confirme el problema. Si lo deseas, te mencionaremos en las notas de la versión.

## Qué se considera en el alcance

- Lectura o escritura de archivos fuera de la biblioteca o la carpeta de exportación elegida (por ejemplo, plantillas de nombre que escapen de la carpeta).
- Ejecución de acciones sin la confirmación del usuario a través de `nativeshot://`, de archivos de ajustes importados o de contenido reconocido (códigos QR).
- Inyección en la base de datos de la biblioteca o corrupción por archivos manipulados (`.nshot`, proyectos de vídeo, JSON de ajustes).
- Fugas de capturas, texto reconocido o audio hacia fuera del Mac.
- Fallos en la validación de paquetes (`.nshot`) frente a archivos comprimidos maliciosos o corruptos.

Fuera del alcance: problemas que exijan acceso físico y sesión desbloqueada del usuario, o que dependan de desactivar protecciones de macOS.

## Decisiones de diseño relevantes

- Sin servidor ni cuentas: no hay credenciales que robar. Los secretos, si algún día existieran, irían al Llavero.
- Sin red al arrancar. La única petición posible es la comprobación manual de versión.
- Todas las sentencias SQL están parametrizadas; la entrada de búsqueda se convierte en términos entrecomillados.
- Las URL `nativeshot://` están desactivadas por defecto, se analizan de forma estricta (solo un nombre de acción, sin parámetros), exigen lista de acciones permitidas y confirmación en cada uso.
- La importación de ajustes valida clave, tipo y rango de cada valor y no puede activar las acciones por URL.
- Los nombres de archivo generados se limpian de separadores y caracteres de control, y nunca sobrescriben un archivo existente.

## Divulgación

Preferimos la divulgación coordinada: acordamos contigo un plazo razonable antes de publicar los detalles.
