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
- **Diarización que llega al transcript** — pyannote separaba las voces desde el
  principio, pero el resultado se descartaba por un desajuste de etiqueta entre el
  writer en vivo y el reescritor post-sesión. Arreglado junto al origen de tiempos
  del WAV, el frontmatter que mentía, la reescritura sobre el fichero equivocado y
  los `stopSession` reentrantes. Ver [`CHANGES-diarization-fix.md`](CHANGES-diarization-fix.md).

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

### Atribución fina de speakers en cross-talk (prioridad baja — medir antes)

El sello de tiempo de cada línea del transcript es el instante en que la ASR
**terminó** de transcribir, no cuando se habló, y `StreamingTranscriber`
(`flushInterval`) corta cada 30 s. En intervenciones largas el sello puede ir muy
por detrás del habla, y cuando varias voces caen en el mismo chunk la línea
entera recibe una sola etiqueta.

**Coste real medido** en la reunión de validación (5-ago, 23 min, 4 personas): 1
línea de 70 — la despedida a tres voces. Las otras 7 líneas fallidas son
monosílabos (`Vale`, `Mm-hmm`) que ninguna mejora de timing rescata, porque el
problema ahí es que pyannote no los segmenta.

> **Antes de tocar nada: grabar 2-3 reuniones más.** Con una sola sesión no se
> sabe si el ~90 % de cobertura es lo normal o suerte. Sería una pena operar sobre
> el writer en vivo para arreglar un problema que resulta ser marginal.

Plan, si los datos lo justifican:

1. **Reloj de muestras en `StreamingTranscriber`** — contar las muestras
   consumidas del stream y registrar el offset en `speechStart` y en cada flush,
   para tener el intervalo `[inicio, fin]` real de cada intervención en segundos
   de audio. El escritor del WAV y el transcriptor consumen la *misma* secuencia
   de callbacks de ScreenCaptureKit y el `AsyncStream` no descarta buffers, así
   que esos offsets comparten origen con la línea temporal del diarizador. El
   ancla de reloj de pared pasaría a ser fallback.
2. **Propagar el intervalo** por `Utterance` → `TranscriptStore` →
   `ContentView.handleNewUtterance` → `TranscriptLogger.append`, y cambiar el
   matching de "¿el instante cae dentro del segmento? si no, el midpoint más
   cercano a <10 s" por **solape máximo de intervalos**. El markdown no cambia:
   los intervalos viven solo en memoria, que basta porque la reescritura ocurre en
   la misma ejecución.
3. **Partir el chunk donde cambia el speaker dominante.**
   **`ASRResult.tokenTimings` ya trae `startTime`/`endTime` por token** y
   `AsrManager+Transcription.swift` lo rellena siempre en la ruta que usamos
   (`transcribe(samples, source:)`). Es decir: el alineamiento word-level que el
   análisis original apuntaba como "robar de WhisperX" **ya está en el motor que
   corre**. No hace falta wav2vec2 ni migrar de app.

**Opción barata alternativa**: bajar `flushInterval` de `480_000` (30 s) a
`160_000` (10 s) en `StreamingTranscriber`. Una constante. Acerca el sello al
habla y reduce el solape por chunk, a cambio de menos contexto para Parakeet —el
propio comentario del código dice que los chunks largos le dan mejor precisión,
así que es un intercambio real. Mitiga el problema, no lo arregla.

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
- **`Them` no debería contar como asistente** — hoy las líneas sin atribuir dejan
  `Them` en `attendees:` y en `**Speakers:**`. Es honesto sobre la cobertura, pero
  confunde al paso de poner nombres reales cruzando con el calendario. Candidato:
  excluirlo del conteo y de la lista, dejándolo solo en el cuerpo.
- **La duración se pasa unos segundos** — `finalizeFrontmatter` mide con `Date()` y
  corre después de la diarización, así que le suma el tiempo de proceso (18 s sobre
  23 min en la reunión de validación). Arreglo trivial: usar el instante de
  `endSession`.
- **Numerar los speakers por orden de aparición** — hoy `Speaker 2/3/4` sale del
  orden del array de segmentos de pyannote, que no está verificado que sea
  cronológico (en la reunión de validación `Speaker 2` es la última línea del
  fichero). Numerar por el `startTime` más temprano de cada voz haría las etiquetas
  intuitivas.
- **Aviso en UI cuando no hay audio de sistema** — `[DIARIZE] No buffered system
  audio file found` y los `[ENGINE-5-FAIL]` de TCC solo se ven en el log. Tras
  refirmar la app (ad-hoc cambia la identidad de código) macOS revoca el permiso de
  grabación de pantalla y la sesión graba sin la otra parte, en silencio.
- Contexto de cliente pre-llamada (estilo Detto) — *descartado por ahora*.
