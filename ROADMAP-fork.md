# Roadmap del fork

Roadmap propio de este fork de Tome (no confundir con `ROADMAP.md`, que es el del
proyecto original). Recoge lo ya hecho aquí y lo que tiene sentido mejorar a
continuación.

## Hecho en este fork

- **Auto-start/stop por detección de reunión** — inicia/para la transcripción
  automáticamente cuando una app de conferencia (Teams, Zoom…) usa el micrófono.
  Detección por proceso vía CoreAudio. Ver [`CHANGES-auto-start.md`](CHANGES-auto-start.md).
- **Blindaje anti-crash de `installTap`** — shim Obj-C `@try/@catch` que convierte
  las `NSException` de CoreAudio en errores recuperables, más watchdog de sesiones
  zombi. Ver [`CHANGES-crash-fix.md`](CHANGES-crash-fix.md).
- **Limpieza de sesión al auto-abortar el engine** — si el watchdog mata una
  sesión zombi, la sesión se finaliza correctamente (cierra el logger) para que el
  auto-start no quede bloqueado pidiendo reinicio.
- **Vocabulario personalizado** — correcciones (`patrón = reemplazo`) y términos
  para arreglar nombres y jerga en los transcripts. Ver [`VOCABULARY.md`](VOCABULARY.md).

## Próximo

### Refinamiento LLM on-device (prioridad alta)

Limpiar el texto crudo del ASR —puntuación, mayúsculas, orden de palabras y
términos con contexto— usando un modelo local, sin enviar nada a la nube. Es la
solución real al mantenimiento manual del vocabulario: el modelo arregla con
contexto lo que las reglas no escalan a cubrir.

- **Enfoque:** reimplementación limpia inspirada en Detto (Llama 3.2 3B 4-bit vía
  MLX en GPU). **Sin copiar código** — Detto es BSL 1.1, este fork es MIT.
- **Primera versión:** refinamiento **post-sesión** (batch sobre el transcript
  completo), que es más simple y de menor riesgo que el refinamiento en vivo.
- **Punto de integración:** tras la diarización y antes de `finalizeFrontmatter`.
- **A decidir:** dependencia de MLX Swift, modelo y cuantización, prompt de
  refinamiento, descarga del modelo (~2 GB) y caché, toggle en Settings.
- **Trade-off:** un modelo local pequeño no iguala a uno frontier en pulido; es el
  precio de que nada salga del Mac.

## Otras mejoras candidatas

### Vocabulario
- **Recarga en caliente** del vocabulario sin tener que reiniciar la sesión.
- **Editor en la UI** para gestionar términos/correcciones sin editar `.txt` a mano.
- **Aplicar vocabulario al texto parcial en vivo**, no solo a la utterance final.
- Fuzzy en minúscula para términos largos — *descartado por ahora* (riesgo de
  falsos positivos; se mantiene solo-mayúsculas).

### Robustez y captura
- **Recuperación desde JSONL** — reconstruir el transcript si la app muere a media
  sesión (ya estaba en el roadmap upstream).
- **Reintento de `installTap` con formato nativo** (`tapFormat = nil`) si el
  format-mismatch de macOS 26 se vuelve frecuente.
- **Debounce de auto-stop configurable** (hoy fijo en 20 s en `MeetingDetector`).

### Salida / vault
- **Plantilla de frontmatter configurable** desde Settings.
- Contexto de cliente pre-llamada (estilo Detto) — *descartado por ahora*.
