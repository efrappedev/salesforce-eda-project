# Android iJiami Bypass — Contexto completo
**Última actualización:** 2026-06-11  
**Repo:** github.com/efrappedev/salesforce-eda-project  
**Proyecto:** Ingeniería inversa de app IPTV `com.android.mgstv` protegida con iJiami

---

## APK objetivo (archivos locales — NO en GitHub)
- `Apk/Xuper_4.34.5_Emagoplay.apk` — original, certificado SGM (35MB)
- `Apk/Xuper_4.34.5_CLEAN.apk` — re-firmado con debug cert, trackers removidos (33MB)
- **Package:** `com.android.mgstv`
- **Application class:** `s.h.e.l.l.S` | **AppComponentFactory:** `s.h.e.l.l.A`
- **Activity principal:** `com.interactive.brasiliptv.ui.activity.WelcomeActivity`
- **PORTAL_KEY** (AndroidManifest metadata): hex `59507a77...3d3d` → base64 `YPzwpHii1XawHe1L+BBwzfOG7UWqu119mBXlqOgeSGu0vuIYh37fR8w==`
- **Servicio separado:** `com.main.service.GoMediaService` en proceso `:gomediad`

---

## Entorno de trabajo
- **Emulador:** Android Studio AVD Google APIs ARM64, rooteado con `adb root`
- **Frida:** 17.11.0 en `/data/local/tmp/frida-server` (emulador)
- **adb:** `/Users/e.frappe/Library/Android/sdk/platform-tools/adb`
- **frida CLI:** `/Users/e.frappe/Library/Python/3.9/bin/frida`
- **Android version:** Android 14 (build fingerprint `google/sdk_gphone64_arm64/emu64a:14/...`)
- **Comando spawn estándar:** `frida -U -f com.android.mgstv -l /path/to/script.js`
- **NordVPN:** México activo en Mac (IP: 192.154.196.51, Iztacalco) — emulador usa internet del Mac

---

## Arquitectura iJiami (capas descubiertas)

1. **Triple raise(SIGSTOP=19):** antes de ART — hook libc.raise → set signal=0
2. **2 kill threads anónimos (684KB):** creados con pthread_create → redirigir a noopThread
3. **163 kill SVCs** (syscalls 93/94/129/130/131) en región 684KB — scan ARM64 → NOP
4. **16 BRK instructions** en región 684KB — scan ARM64 → NOP
5. **Access-violation traps** en región iJiami → exception handler selectivo
6. **Null-call traps** (BLR Xn donde Xn=0) → if PC=0x0 && LR in iJiami → PC=LR
7. **Kill threads via SIGSEGV deliberado:** kill threads hacen mprotect → auto-descifrado → si detectan debug → dereferencia puntero inválido → SIGSEGV mata el proceso

### Clases Java iJiami (s.h.e.l.l.N)
Métodos nativos en libexecmain.so (RegisterNatives interceptados):
- `N.l(Application, String)Z` — en attachBaseContext, return DESCARTADO en Java
- `N.r(Application, String)Z` — en attachBaseContext, return DESCARTADO
- `N.ra(Application, ...)Z` — en onCreate, return DESCARTADO
- `N.m, N.b2b, N.sa, N.al, N.i, N.println_native` — otros métodos

**CRÍTICO:** return values de N.l/N.r/N.ra NO se usan (no hay `move-result` en smali).

### libart.so — RegisterNatives offsets (emulador actual)
- Lb0: offset `0x54b318`
- Lb1: offset `0x40f808`
- Archivo: `/apex/com.android.art/lib64/libart.so` (12,725,256 bytes)

---

## Estado actual del bypass (2026-06-11)

### ✅ LO QUE FUNCIONA
- App muestra splash screen (logo XUVER TV) con `kills_only.js`
- Bypass nativo completo: 163 kills, 16 BRKs, raise, tgkill/kill/pthread_kill
- noopThread detiene los kill threads (NECESARIO — sin él el proceso crashea)
- RegisterNatives interceptados: se ven los métodos N.l, N.r, N.ra, etc.
- App sobrevive indefinidamente con kills_only

### 🔴 PROBLEMA CENTRAL: Spin-loop del thread principal
- Con noopThread: proceso vivo PERO main thread en **spin-loop permanente** (wchan=0, sc=running)
- Los kill threads normalmente: verifican → señalan condición al main thread → continúan
- noopThread duerme 300ms y sale SIN señalar → main thread gira para siempre
- WelcomeActivity.onCreate NUNCA ejecuta → cero conexiones TCP al exterior

### 🔴 PROBLEMA SECUNDARIO: Java.perform no dispara
- `Java.available = true` ✓
- `setTimeout` callbacks funcionan ✓
- `Java.perform(fn)` → callback NUNCA ejecuta (ni en spawn ni en attach mode)
- pool-frida thread en futex_wait permanente
- Causa probable: iJiami llama ART's `SuspendAll()` o deadlock en ART locks

### 🔎 Diagnóstico del mecanismo kill (v67)
Kill threads (sin noopThread):
- Hacen `mprotect(region, prot=7)` → auto-descifrado de su propio código
- Código descifrado verifica condiciones → si debug detectado → accede puntero inválido deliberadamente → SIGSEGV → mata proceso
- Nuestros NOP patches corrompen el descifrado → crash accidental (en lugar de kill controlado)
- **Thread 30115:** sale limpiamente (`pthread_exit`)
- **Thread 30114:** SIGSEGV en `0x7645a99850`, fault addr `0x000380b08e4780b0`

---

## Próximos pasos

### Opción A — Resolver el spin-loop (continuar en emulador)
1. **Stalker en main thread** para localizar el spin-loop y la dirección que espera
   ```javascript
   Stalker.follow(mainThreadId, { events: { call: true, ret: true }, onReceive: ... });
   ```
2. Encontrar la dirección que los kill threads deben señalar
3. Escribir ese valor desde Frida manualmente

### Opción B — Fire TV real (hardware) — MÁS FÁCIL
1. Conectar Fire TV vía ADB: `adb connect <ip_firetv>`
2. Capturar logcat mientras corre la app original:
   ```bash
   adb logcat | grep -iE "http|url|portal|mgstv|brasiliptv|server|connect"
   ```
3. Si tiene proxy MITM (mitmproxy en Mac): interceptar HTTPS
   - Mac: `mitmproxy --listen-port 8080`
   - Fire TV: configurar proxy WiFi → IP Mac:8080
4. Las URLs del portal IPTV aparecerán sin necesitar bypass del emulador

### Opción C — dl_iterate_phdr hook (anti-emulator en memoria)
iJiami NO usa `openat` para leer `/proc/self/maps` (nunca disparó `[MAPS-OPEN]`)
Probablemente usa `dl_iterate_phdr` para enumerar librerías cargadas (busca `ranchu`, `_enc.so`)
```javascript
var dl_fn = Module.findExportByName(null, "dl_iterate_phdr");
Interceptor.attach(dl_fn, { onEnter: ..., onLeave: ... });
```

---

## Referencia ARM64 / Frida

```
NOP          = 0xD503201F
RET          = 0xD65F03C0
MOVZ X8, #N  = 0xD2800008 | (N << 5)   // JS: (0xD2800008|0)
SVC #0       = 0xD4000001
BRK #N base  = 0xD4200000 | 0
Mask imm16   = 0xFFE0001F | 0
Syscalls: exit=93, exit_group=94, kill=129, tkill=130, tgkill=131

Memory.protect(addr, 4, 'rwx') ANTES de writeU32()
Frida 17.11.0 API:
  - libc.findExportByName("name")  ← NO Module.findExportByName(null, "name")
  - ptr.writeUtf8String(str)        ← NO Memory.writeUtf8String(ptr, str)
  - NO usar Unicode en comentarios JS (causa parse error en Frida 17)
```

## Scripts en `android/scripts/`

| Script | Descripción | Estado |
|--------|-------------|--------|
| `kills_only.js` | Solo kills bypass, sin spoofing | ✅ Referencia base funcional |
| `bypass_v58.js` | Primer splash visible | ✅ Histórico |
| `bypass_v62.js` | kills + prop spoofing + maps filter (read hook = ANR) | ⚠️ ANR con read hook |
| `bypass_v64.js` | kills + prop spoof mínimo + strstr | ❌ Pantalla blanca con ro.hardware |
| `bypass_v65_trace.js` | kills + Java trace Activity/OkHttp/ClassLoader | ⚠️ Java.perform nunca dispara |
| `bypass_v66.js` | Sin noopThread — threads corren libres | ❌ Proceso crashea (SIGSEGV) |
| `bypass_v67_diag.js` | Diagnóstico completo kill threads | ✅ Diagnóstico confirmado |

## Cómo retomar desde cualquier máquina

```bash
# 1. Clonar repo
git clone https://github.com/efrappedev/salesforce-eda-project
cd salesforce-eda-project

# 2. Iniciar Claude Code
claude

# 3. Decirle a Claude:
# "lee android/CONTEXTO.md y continuemos con el bypass de iJiami"

# Para trabajo con emulador (necesita Android Studio + AVD):
export PATH="$PATH:~/Library/Android/sdk/platform-tools:~/Library/Python/3.9/bin"
adb root
adb shell "/data/local/tmp/frida-server &"
frida -U -f com.android.mgstv -l android/scripts/kills_only.js

# Para trabajo con Fire TV (solo necesita adb):
adb connect <ip_firetv>
adb logcat | grep -iE "http|url|portal|brasiliptv"
```
