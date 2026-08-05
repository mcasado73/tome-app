# Fix de diarización: el resultado se calculaba y se tiraba

## Resumen

Tome diarizaba correctamente desde el principio —pyannote separaba hasta 5 voces
del audio mezclado de Teams— pero **el resultado nunca llegaba al transcript**.
Todas las sesiones acababan con dos etiquetas: `You` y `Speaker 2`.

La causa no era el motor de diarización. Era un desajuste de contrato entre el
writer en vivo y el reescritor post-sesión: **hablaban idiomas distintos**.

Evidencia previa al fix, en `/tmp/tome.log`:

```
2026-08-04 08:42:45  [DIARIZE] Found 142 segments, 5 speakers
2026-08-04 12:25:16  [DIARIZE] Found 301 segments, 3 speakers
2026-08-03 11:44:51  [DIARIZE] Found  29 segments, 3 speakers
```

Cada una de esas sesiones acabó en el vault como `You` + `Speaker 2`.

Después del fix, primera reunión real (5-ago, 23 min, 4 personas):

```
08:56:42  [DIARIZE] Found 220 segments, 3 speakers
08:56:43  [DIARIZE] Rewrote 63/70 lines as 3 speakers, 7 left as Them
```

63 de 70 intervenciones reetiquetadas a `Speaker 2/3/4`, donde antes eran 0. Las
7 restantes son monosílabos de asentimiento (`Vale`, `Yeah`, `Mm-hmm`) que
pyannote descarta por cortos.

## Causa raíz

El pipeline estaba completo; el handoff estaba roto en dos puntos independientes.

### 1. Desajuste de etiqueta

| Paso | Fichero | Qué hacía |
|---|---|---|
| Escritura en vivo | `ContentView.handleNewUtterance()` | Pasa `speaker: "Them"` al logger para todo el audio de sistema |
| Etiquetado | `TranscriptLogger.labelForSpeaker()` | `"Them"` no es `"you"` → devolvía `"Speaker 2"` y lo cacheaba en `speakerLabels`. **Todas** las intervenciones siguientes reusaban ese mismo `"Speaker 2"` |
| Volcado | `TranscriptLogger.flushBuffer()` | Escribía `**Speaker 2** (HH:mm:ss)` |
| Reescritura | `TranscriptLogger.rewriteWithDiarization()` | Buscaba el regex `\*\*Them\*\* \((\d{2}:\d{2}:\d{2})\)` → **el fichero nunca contenía `**Them**`** → 0 matches → guardaba el fichero idéntico |

La caché `speakerLabels` era el bug. Se ha eliminado: `labelForSpeaker` ahora
devuelve `Them` y asignar números de speaker es responsabilidad exclusiva del
reescritor post-sesión.

### 2. Origen de tiempos equivocado

El WAV de diarización se crea en el **primer callback de audio**, no al empezar
la sesión:

```
ContentView.startSession()      → transcriptLogger.startSession()   ← t=0 del transcript
                                → engine.start()
                                    carga Parakeet v3 + 2× VAD
                                    arranca ScreenCaptureKit
SystemAudioCapture.stream(...)  → AVAudioFile(forWriting:)          ← t=0 del WAV
```

`rewriteWithDiarization` calculaba el offset de cada línea contra
`sessionStartTime`, pero los segmentos del diarizador vienen referidos al inicio
del WAV. Aunque se arreglase el regex, cada atribución habría salido desplazada
por ese hueco.

`SystemAudioCapture` ahora sella un `_bufferStartWallClock` en el primer sample
escrito y lo entrega junto al fichero, y el reescritor ancla ahí.

> **Magnitud medida**: con los modelos ya cacheados el hueco es de ~1 s
> (`[ENGINE-1]` 08:33:20 → `[ENGINE-5]` 08:33:21), no los segundos que se
> estimaron al diagnosticar. El fix elimina un error sistemático y en arranque
> frío —con descarga de modelos— sería grande, pero **no es lo que produjo los 63
> aciertos**: eso fue el desajuste de etiqueta.

## Bugs de segundo orden arreglados en el mismo viaje

### El frontmatter mentía

`lastSpeakersDetected` se llenaba con las etiquetas **en vivo** (`You`/`Them`), y
`finalizeFrontmatter()` corre **después** de `rewriteWithDiarization()`,
sobrescribiendo el conteo que este último había calculado. El cuerpo podía tener
4 voces y la cabecera decir 2.

El reescritor ahora realimenta `lastSpeakersDetected` con las etiquetas
realmente aplicadas, añadiendo `You` solo si el cuerpo lo contiene y `Them` solo
si quedan líneas sin atribuir. Se eliminó la actualización de `**Speakers:**` que
hacía el reescritor, porque `finalizeFrontmatter` la sobrescribía de todos modos.

### Reescritura sobre el fichero equivocado

`rewriteWithDiarization` resolvía el destino como
`currentFilePath ?? lastSessionFilePath`. Con auto-start, si una reunión nueva
arrancaba mientras se diarizaba la anterior, **reescribía el transcript nuevo**.
Mismo problema con `sessionStartTime ?? lastSessionStartTime`.

En vez de invertir el orden de los `??`, cada sesión lleva ahora un ID monótono:
`endSession()` lo emite y `rewriteWithDiarization` / `finalizeFrontmatter` /
`collapseUnattributedSpeakers` lo exigen. Una diarización que termina después de
que haya arrancado *y acabado* otra sesión se descarta con log en vez de escribir
sobre el fichero nuevo.

### `stopSession` reentrante y WAVs huérfanos

Tres disparadores independientes pueden llamar a `stopSession()`: el timeout de
silencio (120 s), el `MeetingDetector`, y el observador de `isRunning` cuando el
engine se aborta solo. El bucle de silencio comprueba `isRunning`, que solo pasa
a `false` *dentro* del `Task`, así que podía llamar dos veces. La segunda llamada
a `endSession()` ponía `lastSessionFilePath = nil` → la reescritura se descartaba
en silencio y no salía el banner de guardado.

En paralelo, `bufferStream()` sobrescribía `_bufferFilePath` al arrancar sesión
nueva, así que `cleanupBufferFile()` de la sesión anterior borraba el WAV de la
**nueva**.

**Los dos síntomas que parecían independientes eran el mismo cruce de punteros.**
Reconstrucción a partir del log del 4-ago:

```
12:25:16  [DIARIZE] Starting post-session diarization on ...29C34A4D....wav   ← sesión A
12:25:39  [AUTO-START] starting session for Teams                            ← sesión B pisa _bufferFilePath
12:26:34  [DIARIZE] Found 301 segments, 3 speakers                            ← A limpia el WAV de B
12:39:25  [DIARIZE] No buffered system audio file found                       ← B se queda sin audio
```

El WAV de A (630 MB, 55 min a 48 kHz float32) quedó huérfano en `$TMPDIR` para
siempre. Se encontró intacto un día después, y es la prueba física del bug.

Arreglos:
- Guard de reentrada en `stopSession()`, liberado **al terminar el teardown** y
  no al final del `Task` — mantenerlo durante la diarización habría bloqueado el
  cierre de la sesión *siguiente* (minutos en una reunión larga).
- `endSession()` devuelve `nil` si no había sesión activa, en vez de limpiar el
  estado que el trabajo post-sesión todavía necesita.
- `detachBuffer()` sustituye a `cleanupBufferFile()`: entrega el WAV al llamante
  y suelta la referencia **antes del primer `await`**, así que una sesión nueva no
  puede ni sobrescribirlo ni borrarlo. `bufferStream()` limpia el WAV huérfano de
  la sesión anterior al arrancar (las notas de voz nunca diarizan y dejaban el
  suyo sin borrar).

## Fallback

Si la diarización devuelve `nil` o 0 segmentos —o la sesión es una nota de voz,
que nunca diariza— `collapseUnattributedSpeakers()` convierte los `Them`
restantes en `Speaker 2`, para que el transcript se lea como una conversación de
dos.

Cuando la diarización **sí** atribuye, las líneas que no encajan se quedan como
`Them` a propósito: muestran la cobertura real del diarizador de un vistazo en
vez de esconder los huecos detrás de un número de speaker plausible.

## Ficheros tocados

| Fichero | Cambio |
|---|---|
| `Storage/TranscriptLogger.swift` | Contrato de etiquetas, IDs de sesión, ancla de tiempos, realimentación del frontmatter, fallback de colapso |
| `Audio/SystemAudioCapture.swift` | `_bufferStartWallClock`, `detachBuffer()`/`removeBuffer()`, limpieza de huérfanos |
| `Transcription/TranscriptionEngine.swift` | `DiarizedSegment` / `PostSessionDiarization`, detach antes del primer `await` |
| `Views/ContentView.swift` | Guard de reentrada, propagación del ID de sesión, rama de fallback |

## Verificación

1. `grep DIARIZE /tmp/tome.log` → `Found N segments, M speakers` seguido de
   `Rewrote X/Y lines as K speakers, U left as Them`. La segunda línea es nueva y
   da la cobertura real.
2. En el `.md`: deben aparecer `Speaker 2`, `Speaker 3`, `Speaker 4`… no uno solo.
3. `attendees:` del frontmatter y `**Speakers:**` de la cabecera deben cuadrar con
   las etiquetas del cuerpo.
4. Sin `[LOGGER] endSession called with no active session` ni
   `[STOP] stopSession already in progress` en el log de una sesión limpia.
5. Sin WAVs `tome_sys_audio_*.wav` en `$TMPDIR` tras cerrar sesión.

## Limitación conocida: cross-talk

El sello de tiempo de cada línea es el instante en que la ASR **terminó** de
transcribir, no cuando se habló, y `StreamingTranscriber.flushInterval` corta
cada 30 s. Consecuencias visibles en el transcript de validación:

- Un monólogo largo sale partido en líneas a intervalos de exactamente 30 s
  (inofensivo: habla una sola persona).
- Una despedida a tres voces solapadas cayó en un único chunk y recibió **una
  sola etiqueta**, elegida a suertes entre las voces presentes.

Coste real medido: 1 línea de 70. Ver `ROADMAP-fork.md` para el plan de arreglo
—y el hallazgo de que `ASRResult.tokenTimings` ya trae alineamiento a nivel de
token, así que no hace falta nada de WhisperX.
