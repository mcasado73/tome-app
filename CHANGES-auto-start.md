# Auto-start transcription on meeting detection

## Resumen

Se ha implementado la funcionalidad de inicio/parada automática de transcripción
cuando se detecta que una app de conferencia (Teams, Zoom, etc.) está en una llamada activa.

La detección se basa en monitorizar el estado del micrófono del sistema via CoreAudio:
cuando otra aplicación activa el micrófono y hay una app de conferencia conocida ejecutándose,
Tome inicia la transcripción automáticamente. Cuando el micrófono se libera (fin de llamada),
Tome detiene la sesión tras un periodo de gracia de 20 segundos.

## Archivos modificados

### Nuevo: `Tome/Sources/Tome/Audio/MeetingDetector.swift`

Clase `MeetingDetector` que encapsula toda la lógica de detección:

- **Listener CoreAudio**: escucha `kAudioDevicePropertyDeviceIsRunningSomewhere` en el
  dispositivo de entrada por defecto del sistema. Este property cambia cuando cualquier app
  empieza o deja de usar el micrófono.
- **Detección de app de conferencia**: cuando el micrófono se activa, consulta
  `NSWorkspace.shared.runningApplications` buscando bundle IDs conocidos (Teams, Zoom,
  FaceTime, Slack, Webex, Chrome, Arc, Safari, Edge).
- **Debounce de parada**: cuando el micrófono se libera, espera 20 segundos antes de señalar
  el fin de la reunión. Si el micrófono se reactiva durante ese periodo (por ejemplo, el
  usuario se desmutea), se cancela la parada. Esto evita falsos positivos por mutes breves.
- **Re-attach automático**: si el dispositivo de entrada por defecto del sistema cambia
  (por ejemplo, el usuario conecta unos auriculares), el listener se re-adjunta al nuevo
  dispositivo automáticamente.
- **Callbacks**: expone `onMeetingStarted` y `onMeetingStopped` que ContentView conecta
  a `startSession` y `stopSession`.

### Modificado: `Tome/Sources/Tome/Settings/AppSettings.swift`

- Nueva propiedad `autoStartEnabled: Bool` (persiste en `UserDefaults` con clave
  `"autoStartEnabled"`). Por defecto `false` (desactivado).

### Modificado: `Tome/Sources/Tome/Views/SettingsView.swift`

- Nueva sección **"Automation"** en el formulario de preferencias con un toggle
  "Auto-start on meeting" y texto explicativo.
- Altura del formulario ajustada de 420 a 500 para acomodar la nueva sección.

### Modificado: `Tome/Sources/Tome/Views/ContentView.swift`

- Nuevo `@State`: `meetingDetector = MeetingDetector()`.
- Nuevo `.task` que llama a `setupMeetingDetector()` y activa el detector si el setting
  está habilitado al arrancar la app.
- Nuevo `.onChange(of: settings.autoStartEnabled)` para activar/desactivar el detector
  en caliente cuando el usuario cambia el toggle en Settings.
- Nuevo método `setupMeetingDetector()` que conecta los callbacks del detector:
  - `onMeetingStarted` → inicia sesión de call capture (solo si no hay sesión activa).
  - `onMeetingStopped` → detiene la sesión (solo si hay una call capture activa).
- Nuevo método `startSession(appBundleID:appName:)` — variante de `startSession(type:)`
  que recibe directamente el bundle ID y nombre de la app detectada, sin necesidad de
  consultar la app en primer plano (ya que la detección viene del MeetingDetector).

## Flujo de funcionamiento

```
1. Usuario activa "Auto-start on meeting" en Settings
2. MeetingDetector.install() → registra listener CoreAudio
3. Usuario entra a una reunión de Teams
4. Teams activa el micrófono del sistema
5. CoreAudio dispara kAudioDevicePropertyDeviceIsRunningSomewhere
6. MeetingDetector.handleMicRunningChange()
   → isMicRunning() == true
   → findRunningConferencingApp() encuentra "com.microsoft.teams2"
   → onMeetingStarted("com.microsoft.teams2", "Teams")
7. ContentView.startSession(appBundleID:appName:) inicia la transcripción
8. Usuario termina la reunión
9. Teams libera el micrófono
10. CoreAudio dispara el listener de nuevo
11. MeetingDetector espera 20 segundos (debounce)
12. Re-verifica que el mic sigue libre
13. onMeetingStopped()
14. ContentView.stopSession() → diarización + guardado del transcript
```

## Notas

- El toggle está desactivado por defecto. El usuario debe activarlo explícitamente.
- La funcionalidad es compatible con el inicio/parada manual: si el usuario inicia
  manualmente, el detector no interferirá (guard `!isRunning`). Si el usuario para
  manualmente una sesión auto-iniciada, el detector limpia su estado al detectar que
  el mic se libera.
- Los 20 segundos de debounce evitan cortes por mutes momentáneos pero podrían causar
  un retraso al final de llamadas muy cortas. Este valor se puede ajustar en
  `MeetingDetector.stopDelay`.

---

## Iteración 2 — detección por proceso (sesión 2026-04-13)

### Problemas detectados al probar

1. **No se cortaba la transcripción al terminar la reunión de Teams.** Causa: el
   listener global `kAudioDevicePropertyDeviceIsRunningSomewhere` solo dice si
   *alguien* usa el mic. Como Tome activa el mic al iniciar la captura, la propiedad
   se quedaba en `true` aunque Teams liberara el mic, y el debounce de parada nunca
   arrancaba.
2. **Falsos positivos con apps no de conferencia** (Voice Memos, Handy, etc.).
   Causa: la detección se basaba en *"mic activo + app de conferencia corriendo en
   algún sitio"*. Como Teams suele estar siempre abierto en background, cualquier
   otra app que abriera el mic disparaba el inicio.

### Solución: detección por proceso vía CoreAudio

Reescritura completa de `MeetingDetector.swift` para usar las APIs de procesos de
audio de CoreAudio (macOS 14.4+):

- **`kAudioHardwarePropertyProcessObjectList`**: enumera los procesos que participan
  en I/O de audio.
- **`kAudioProcessPropertyIsRunningInput`**: indica, por proceso, si está usando
  entrada de audio en este momento.
- **`kAudioProcessPropertyPID`** + `NSRunningApplication(processIdentifier:)`:
  resuelve PID → bundleID.

Lógica nueva en `currentConferencingInputUser()`: enumera procesos con input
activo, **filtra el PID propio de Tome**, y devuelve el primero que esté en la
lista de conferencing apps. Esto resuelve los dos bugs:

- **Auto-stop**: cuando Teams libera el mic, ya no aparece en la lista de procesos
  con input activo (Tome se filtra), `evaluate()` ve "ninguna conferencing app", y
  arranca el debounce de 20 s → stop.
- **Falsos positivos**: ya no basta con que la app de conferencia esté *corriendo*;
  tiene que estar *capturando audio*. Voice Memos / Handy / etc. no matchean
  porque sus bundle IDs no están en la lista, aunque Teams esté abierto en
  background.

### Polling como mecanismo principal

Al probar, los listeners por proceso (`AudioObjectAddPropertyListenerBlock` sobre
`kAudioProcessPropertyIsRunningInput`) **no se disparaban** cuando Teams abría el
mic — probablemente por usar un proceso helper de audio que no está en la lista
inicial, o porque la observación de propiedades en `AudioObject` de proceso no es
fiable en la práctica.

Solución: añadido `pollTask` que cada 2 s reata listeners y llama a `evaluate()`.
Los listeners se mantienen como complemento (cuando funcionan dan reacción
inmediata), pero el polling garantiza la detección.

### Cambio adicional

`diagLog` (en `TranscriptionEngine.swift`) ya no está envuelto en `#if DEBUG` para
que los diagnósticos a `/tmp/tome.log` funcionen también en builds release. El log
es local y no contiene datos sensibles.

### Archivos modificados en esta iteración

- `Tome/Sources/Tome/Audio/MeetingDetector.swift` — reescrito completo.
- `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` — `diagLog` siempre
  activo.

---

## Iteración 3 — auto-start bloqueado tras auto-abortar el engine (sesión 2026-06-19)

### Problema detectado en uso real

Tras varias reuniones reales con auto-start activado, la app se quedaba "casi
colgada", como si hubiera una transcripción activa que no se podía parar, y solo
se recuperaba reiniciando. En `/tmp/tome.log`:

```
[ENGINE-WATCHDOG] no mic tap activity 15s after start — aborting zombie session
...
[LOGGER] startSession called while previous session active — refusing
[LOGGER] startSession called while previous session active — refusing
```

### Causa raíz

El **watchdog** (ver `CHANGES-crash-fix.md`, fix #3) puede abortar el
`TranscriptionEngine` por su cuenta cuando una sesión arranca pero el micrófono
nunca entrega audio (sesión zombi). Al hacerlo, pone `isRunning = false` pero
**no informa a `ContentView`**: `activeSessionType` sigue en `.callCapture` y el
`TranscriptLogger` se queda con el fichero abierto.

El callback `onMeetingStopped` exigía `guard isRunning, activeSessionType == .callCapture`.
Como tras el abort `isRunning` ya era `false`, cuando la reunión terminaba de
verdad el guard hacía `return` y **nunca limpiaba la sesión**. A partir de ahí,
cada nuevo `[AUTO-START]` era rechazado por el logger (`refusing`) para siempre.

### Solución

`Tome/Sources/Tome/Views/ContentView.swift` — nuevo observador del estado del
engine:

```swift
.onChange(of: transcriptionEngine?.isRunning) { _, running in
    if running == false, activeSessionType != nil {
        diagLog("[AUTO-STOP] engine stopped unexpectedly — finalizing session")
        stopSession()
    }
}
```

Si el engine se para solo (watchdog o error fatal de captura) mientras hay una
sesión lógicamente activa, se finaliza la sesión correctamente (cierra el logger,
diariza, guarda). No hay doble finalización: en una parada normal,
`stopSession()` pone `activeSessionType = nil` de forma síncrona antes de que
`isRunning` cambie, así que el guard `activeSessionType != nil` evita la
reentrada.

### Archivos modificados en esta iteración

- `Tome/Sources/Tome/Views/ContentView.swift` — observador de auto-finalización.

## Iteración 4 — reuniones no detectadas por proceso no reconocido (sesión 2026-07-05)

### Problema detectado en uso real

Con el auto-start activado (`autoStartEnabled = true` confirmado), varias reuniones
seguidas **no arrancaron la transcripción**. El análisis de `/tmp/tome.log` mostró
que el detector sí estaba corriendo y sondeando, pero el proceso que abría el
micrófono nunca casaba con la lista de apps conocidas:

```
2026-07-03 ... [MEETING-DETECT] processes with input active: pid=955 bid=com.microsoft.teams2.modulehost name=Microsoft Teams ModuleHost → match=none
2026-07-05 ... [MEETING-DETECT] processes with input active: pid=781 bid=<no-bundle> name=<no-name> → match=none
```

(Zoom sí funcionaba: el 2026-07-01 casó `us.zoom.xos` y disparó `[AUTO-START]`.)

### Causa raíz

`MeetingDetector.currentConferencingInputUser()` casaba por **bundle ID exacto**
(`conferencingBundleIDs[bid]`), pero:

1. El **Teams nuevo captura el audio en un proceso auxiliar**
   `com.microsoft.teams2.modulehost`, no en `com.microsoft.teams2`. El match exacto
   fallaba en todas las reuniones de Teams (aparece 12.590 veces con `match=none`).
2. Algunas reuniones las servía un proceso **sin bundle ID resoluble**
   (`<no-bundle>` vía `NSRunningApplication`), imposible de casar por bundle.
3. **Firefox** (`org.mozilla.firefox`) tampoco estaba en la lista.

### Solución

`Tome/Sources/Tome/Audio/MeetingDetector.swift`:

- **Match por prefijo** de bundle ID (`bid == prefix || bid.hasPrefix(prefix + ".")`),
  con límite en el punto para evitar falsos positivos. Cubre `...modulehost` de
  Teams y los helpers `.helper` de Chrome/Edge.
- **Fallback por ruta del ejecutable** (`proc_pidpath`) cuando el proceso no tiene
  bundle ID, buscando palabras clave (`microsoft teams`, `zoom`, `firefox`,
  `webex`, `cisco`, `slack`, `google chrome`, `microsoft edge`).
- Añadido **Firefox** a `conferencingBundleIDs`.

Nuevo helper `conferencingName(bundleID:pid:)` que centraliza ambas estrategias, y
`executablePath(forPID:)`.

### Rotación del log de diagnóstico

`Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` — `diagLog()` rota a
`/tmp/tome.log.1` al superar ~5 MB (conserva un backup; el `/tmp/tome.log` había
llegado a 5,8 MB acumulados). Footprint máximo en disco ~10 MB.

### Archivos modificados en esta iteración

- `Tome/Sources/Tome/Audio/MeetingDetector.swift` — match por prefijo + fallback por ruta + Firefox.
- `Tome/Sources/Tome/Transcription/TranscriptionEngine.swift` — rotación de `/tmp/tome.log`.
