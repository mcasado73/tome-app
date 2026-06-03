# Crash fix: `installTap` NSException en `MicCapture`

## Resumen

Tome estaba sufriendo crashes intermitentes (`SIGABRT` → `abort()`) durante
sesiones de transcripción. Los `.ips` reports apuntaban siempre al mismo punto:

```
abort
  ← objc_exception_throw
  ← +[NSException raise:format:]
  ← AUGraphNodeBaseV3::CreateRecordingTap
  ← -[AVAudioNode installTapOnBus:bufferSize:format:block:]
  ← closure #2 in MicCapture.bufferStream(deviceID:)   ← Tome
```

Se documentaron al menos 3 crashes:

| Fecha | Versión | Tipo |
| --- | --- | --- |
| 2026-05-26 18:40 | 1.2.2 | SIGABRT |
| 2026-05-29 11:02 | 1.2.2 | SIGABRT |
| 2026-06-01 10:58 | 1.2.2 | SIGABRT |

Tras el último fix (1-jun), **0 crashes en `~/Library/Logs/DiagnosticReports/`**.
En `/tmp/tome.log` hay 1 evento `[MIC-5-FAIL]` (2-jun 14:04) que antes habría
sido crash y ahora se reporta como error recuperable.

## Causa raíz

`-[AVAudioNode installTapOnBus:bufferSize:format:block:]` lanza una **NSException
de Objective-C** cuando se llama durante una transición del dispositivo de
entrada (AirPods conectando/desconectando, cambio de default device, formato
del input node renegociándose). Mensaje observado:

> *Failed to create tap due to format mismatch, &lt;AVAudioFormat 0x…: 1 ch, 48000 Hz, Float32&gt;*

Swift puro **no puede capturar NSException Obj-C**. Sin un `@try/@catch` en el
camino, el runtime de C++/Obj-C invoca `std::terminate` → `abort()` → el proceso
muere. Esto explica el `SIGABRT` con `abort() called` en `libsystem_c.dylib`.

Factores que aumentaron la frecuencia:

- **`AVAudioEngine` reutilizado entre sesiones** dejaba estado en el input node
  compartido, exacerbando los format mismatch.
- **Setup del engine en el MainActor**: cuando la NSException se propagaba por
  un closure aislado a MainActor, además del crash inmediato, “envenenaba” el
  runtime de Swift Concurrency y la próxima pulsación de cualquier botón
  (`_ButtonGesture`) podía explotar en `swift_task_isMainExecutorImpl`.
- **Doble arranque por auto-start**: el detector de reuniones podía invocar
  `start()` mientras otra `start()` aún estaba en curso, instalando dos taps
  en el mismo bus.

## Fixes (en capas, de menor a mayor blindaje)

Las medidas se han ido añadiendo a lo largo de varias sesiones. La última,
el shim Obj-C, es la que finalmente cortó los crashes.

### 1. Recrear `AVAudioEngine` en cada `bufferStream(...)`

`Tome/Sources/Tome/Audio/MicCapture.swift`

- La propiedad `engine` pasó de `let` a `var` y se reasigna con
  `self.engine = AVAudioEngine()` al inicio de cada llamada.
- Evita que estado residual del engine previo (taps no removidos, conexiones
  rotas tras device-switch) corrompa la nueva sesión.

### 2. Mover el setup del engine fuera del MainActor

`Tome/Sources/Tome/Audio/MicCapture.swift`

- El bloque de configuración (`setInputDevice`, lectura de format, `installTap`,
  `engine.prepare`, `engine.start`) se ejecuta dentro de un `Task.detached`.
- Si CoreAudio lanza NSException o bloquea por dentro, no afecta al MainActor
  ni envenena el runtime de Concurrency.

### 3. Watchdog de 15 s para sesiones zombi

`Tome/Sources/Tome/Transcription/TranscriptionEngine.swift`

- Nueva propiedad `watchdogTask: Task<Void, Never>?` y contador
  `MicCapture.tapCallCount` (`OSAllocatedUnfairLock<Int>`).
- 15 s después de `start()`, si `tapCallCount == 0`, se aborta la sesión con
  log `[ENGINE-WATCHDOG] no mic tap activity 15s after start — aborting zombie session`
  y `lastError = "Audio capture stalled — please restart the session"`.
- Cubre el caso en que `installTap` retorna sin excepción pero el tap nunca
  entrega callbacks (otra patología de CoreAudio en macOS 26.x). Confirmado
  en logs: se ha disparado 2 veces con éxito.

### 4. Claim atómico de `isRunning` antes del primer `await`

`Tome/Sources/Tome/Transcription/TranscriptionEngine.swift`

- `start()` ahora pone `isRunning = true` **antes** del `await ensureMicrophonePermission()`.
- Una segunda llamada concurrente a `start()` ve `isRunning=true` y devuelve
  inmediatamente con `[ENGINE-0] start() skipped — already running`.
- Evita doble instalación de tap cuando auto-start y un click humano coinciden.

### 5. Defensa en `TranscriptLogger.startSession`

`Tome/Sources/Tome/Storage/TranscriptLogger.swift`

- Si `fileHandle != nil` al entrar (sesión previa no cerrada), lanza
  `TranscriptLoggerError.sessionAlreadyActive` en vez de pisar el handle.
- Log: `[LOGGER] startSession called while previous session active — refusing`.

### 6. Despacho de handlers de botón vía `DispatchQueue.main.async`

`Tome/Sources/Tome/Views/ContentView.swift`

- Los handlers `onStartCallCapture`, `onStartVoiceMemo`, `onStop` y el botón
  *Show in Finder* envuelven la lógica en `DispatchQueue.main.async { … }`.
- Workaround del bug de SwiftUI en macOS 26.4 donde `_ButtonGesture` →
  `MainActor.assumeIsolated` crashea en `swift_task_isMainExecutorImpl`. Romper
  la cadena de aislamiento previene la cascada cuando el runtime ya está
  envenenado por otro fallo.

### 7. **Shim Obj-C `@try/@catch` alrededor de `installTap`** ← fix definitivo

Nuevo target SwiftPM `MicCaptureShim`:

- `Tome/Sources/MicCaptureShim/include/MicCaptureShim.h`
- `Tome/Sources/MicCaptureShim/MicCaptureShim.m`
- `Tome/Package.swift`: target `.target(name: "MicCaptureShim", …)` y dependencia
  desde el target `Tome`.

API expuesta:

```objc
BOOL MCInstallTapOnNode(AVAudioNode *node,
                        NSUInteger bus,
                        UInt32 bufferSize,
                        AVAudioFormat * _Nullable format,
                        AVAudioNodeTapBlock block,
                        NSError * _Nullable __autoreleasing * _Nullable outError);
```

El cuerpo es un `@try { installTap … } @catch (NSException *e) { *outError = … return NO; }`.
La NSException se traduce a `NSError` con `domain="io.gremble.tome.MicCaptureShim"`,
`localizedDescription = exception.reason`, `userInfo["ExceptionName"] = exception.name`.

`MicCapture.bufferStream` ahora:

```swift
inputNode.removeTap(onBus: 0)  // defensivo, no-op si no hay tap

var installError: NSError?
let installed = MCInstallTapOnNode(inputNode, 0, 4096, tapFormat, { buffer, _ in
    …
}, &installError)

guard installed else {
    let reason = installError?.localizedDescription ?? "unknown"
    let msg = "Failed to install audio tap: \(reason)"
    diagLog("[MIC-5-FAIL] \(msg)")
    errorHolder.value = msg
    continuation.finish()
    return
}
```

Tradeoffs / limitaciones:

- El shim solo captura excepciones lanzadas **durante** `installTap`. Si una
  futura excepción se lanzara desde el callback del tap (hilo de audio), el
  `@try/@catch` no la atraparía. Ninguno de los 3 crash reports correspondía a
  ese caso.
- Si la causa raíz de la NSException (format mismatch) se vuelve frecuente,
  considerar reintentar con `tapFormat = nil` (formato nativo del nodo, sin
  conversión). Por ahora el evento es esporádico (1 en 3 días).

## Cambio auxiliar: build script con fallback ad-hoc

`scripts/build_swift_app.sh`

- Si no hay identidad Developer ID / Apple Development, el script ya no aborta:
  cambia a **firma ad-hoc** (`--sign -`) para pruebas locales.
- En modo ad-hoc:
  - Genera un entitlements temporal fusionando `Tome.entitlements` y añadiendo
    `com.apple.security.cs.disable-library-validation` (necesario para cargar
    Sparkle, que tiene Team ID distinto al ad-hoc / vacío del binario).
  - Omite `--timestamp` (sin trust chain).
  - Tras copiar a `/Applications`, hace `xattr -dr com.apple.quarantine` para
    que Gatekeeper no bloquee el lanzamiento.
- El path Developer ID se mantiene idéntico para builds firmadas/notarizadas.
- Forzar ad-hoc explícitamente: `CODESIGN_IDENTITY="-" ./scripts/build_swift_app.sh`.

## Verificación

3 días de uso continuo tras el fix #7:

- **0 crash reports nuevos** en `~/Library/Logs/DiagnosticReports/`.
- 33 arranques de `MicCapture.bufferStream`.
- 4 918 callbacks de tap entregados.
- 48 reconfiguraciones de mic en caliente (`[ENGINE-MIC-SWAP]`).
- **1 `[MIC-5-FAIL]` capturado por el shim** (1-jun 14:04:57, *format
  mismatch* tras transición de dispositivo) — convertido en error recuperable
  en lugar de crash.
- 2 `[ENGINE-WATCHDOG]` disparados con éxito (sesiones zombi cortadas a tiempo).
- 1 `[MIC-2-FAIL]` (device-gone, BT desconectado) y 1 `[ENGINE-5-FAIL]`
  (rechazo TCC del usuario) — comportamientos esperados, manejados.
