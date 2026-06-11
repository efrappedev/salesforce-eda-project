# Checkandroid.md — Sesión bypass iJiami APK
**Última actualización:** 2026-06-11

---

## APK objetivo
- **Archivo:** `Apk/Xuper_4.34.5_Emagoplay.apk` (original, cert SGM)
- **Limpio:** `Apk/Xuper_4.34.5_CLEAN.apk` (re-firmado debug cert)
- **Package:** `com.android.mgstv`
- **Protector:** iJiami (triple SIGSTOP + kill nativo)
- **Application class:** `s.h.e.l.l.S` | **AppComponentFactory:** `s.h.e.l.l.A`
- **Verificación firma:** `assets/sign_verify.png` = 48 bytes (formato desconocido)

---

## ESTADO ACTUAL (2026-06-11)

### ✅ iJiami bypass COMPLETO
El bypass nativo funciona con AMBOS APKs (original y limpio).
Script de referencia: `/tmp/kills_only.js` (mínimo, sin spoofing — base de trabajo actual).

### ✅ Splash screen visible
La app lanza WelcomeActivity y muestra el logo XUVER TV.

### 🔴 BLOQUEO: cero conexiones TCP externas (con y sin VPN)
- NordVPN México activo en Mac (IP: 192.154.196.51, Iztacalco)
- Emulador usa la red del Mac → VPN aplica
- `ss -tnp` confirma: UID 10195 (la app) tiene UNA SOLA conexión TCP → loopback 127.0.0.1:33859 (IPC del sistema Android, UID=0)
- NO hay ninguna petición HTTP hacia el exterior
- Probado con APK original (cert SGM) → mismo resultado que CLEAN APK
- **Conclusión: el bloqueo NO es cert ni VPN — está en la lógica interna de la app**

### 🔍 Teorías activas
1. **iJiami no descifra el DEX en emulador** → WelcomeActivity es un stub vacío (más probable)
2. **WelcomeActivity.onCreate() falla silenciosamente** antes de llegar al código de red
3. **N.l tiene side-effects** que inicializan la URL del portal → falla en emulador y bloquea el arranque

### 📋 PRÓXIMO PASO — Traza Java (bypass_v65_trace.js)
Script creado en `/tmp/bypass_v65_trace.js`:
- Hook `Activity.onCreate` (base) → detecta qué Activities se inician
- Enumera ClassLoaders a t=3s → verifica si WelcomeActivity está cargada
- Hook `URL.openConnection` + OkHttp → detecta si hay intentos de red
- Si `[CL] WelcomeActivity encontrada` → DEX descifrado → problema en lógica interna
- Si NO encontrada → iJiami no descifra → necesitamos forzar descifrado

```bash
# Correr:
adb shell am force-stop com.android.mgstv
frida -U -f com.android.mgstv -l /tmp/bypass_v65_trace.js --no-pause
```

---

## Arquitectura iJiami (descubierta completa)

### Capas de protección nativa
1. **Triple raise(SIGSTOP):** antes de ART — bypasseado con hook de libc.raise
2. **2 kill threads anónimos (684KB):** bypasseados con noopThread en pthread_create
3. **163 kill SVCs** (exit/kill/tkill/tgkill) en región anónima — NOPeados con scan
4. **16 BRK instructions** en región anónima — NOPeadas con scan
5. **Access-violation traps** en iJiami region — manejadas con exception handler
6. **Null-call traps** (BLR Xn, Xn=0) — manejadas: PC=LR (simular return)

### Check de certificado Java (s.h.e.l.l.N)
- `N.l(app, "com.android.mgstv")` — llamado en attachBaseContext, return IGNORADO
- `N.r(app, "com.interactive.brasiliptv.app.AppWrapper")` — mismo
- `N.ra(app, ...)` — llamado en onCreate, return IGNORADO
- **N.l no bloquea la app** — fallo silencioso, el APK limpio funciona igual

### ClassLoader
- Las clases `s.h.e.l.l.*` están en PathClassLoader de `base.apk`
- Para hookear N.l vía Java: `Java.enumerateClassLoaders` + `Java.ClassFactory.get(loader)`
- RegisterNatives en libart.so offsets: Lb0=`0x54b318`, Lb1=`0x40f808`

---

## Scripts Frida (en /tmp/)

| Versión | Qué hace | Resultado |
|---------|----------|-----------|
| v38-v45 | Exploración inicial | Descubrimiento gradual |
| v46-v50 | Timing + mask bugs | Fallos instructivos |
| v51 | Fix signed-int JS | 0 kills detectados → mask bug |
| v54 | patchNop correcto | **App VIVA por primera vez** |
| v55 | NOP BRKs + advance PC | WelcomeActivity en logcat |
| v56 | Exception handler agresivo | Muerto — PC=0x0 ejecuta basura |
| **v57** | Exception handler selectivo | VIVA pero PC=0x0 crash |
| **v58** | NULL-call trap fix (PC=LR) | **SPLASH SCREEN VISIBLE** |
| v59 | TypeError en libart enum | Parcial |
| **v60** | RegisterNatives por offset correcto | N.l interceptado ANTES de primera llamada |
| kills_only | Sin reemplazar N.l (APK original) | Mismo resultado — confirma VPN es el problema |

---

## Entorno
- **Emulador:** Android Studio AVD Google APIs ARM64 (rooteado con `adb root`)
- **Frida:** 17.11.0 en emulador
- **APKLab:** descompila smali, quita trackers, re-firma con debug cert
- **libart.so:** `/apex/com.android.art/lib64/libart.so`

## Referencia ARM64 / Frida
```
ARM64 NOP = 0xD503201F
ARM64 RET = 0xD65F03C0
ARM64 MOV X0, #1 = 0xD2800020
MOVZ X8 base = 0xD2800008 | 0  (signed)
SVC #0 = 0xD4000001
BRK #N base = 0xD4200000 | 0
Mask imm16 = 0xFFE0001F | 0
Syscalls: exit=93, exit_group=94, kill=129, tkill=130, tgkill=131
RegisterNatives (libart Lb0): offset 0x54b318
RegisterNatives (libart Lb1): offset 0x40f808
```
