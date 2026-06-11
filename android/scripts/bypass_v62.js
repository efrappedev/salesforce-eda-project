console.log("[*] bypass_v62 — kills + anti-emulator spoofing");
var libc = Process.findModuleByName("libc.so");
var libart = Process.findModuleByName("libart.so");
var raiseCount = 0;
var scannedBases = {};
var ijiami_base = ptr(0), ijiami_end = ptr(0);
function isInIjiami(p){ return !ijiami_base.equals(ptr(0)) && p.compare(ijiami_base)>=0 && p.compare(ijiami_end)<0; }
var ARM64_NOP=0xD503201F, MOVZ_X8_BASE=(0xD2800008|0), MOVW_W8_BASE=(0x52800008|0), MASK_MOVZW=(0xFFE0001F|0);
var BRK_BASE=(0xD4200000|0), BRK_MASK=(0xFFE0001F|0);
function patchNop(addr){ try{ Memory.protect(addr,4,'rwx'); addr.writeU32(ARM64_NOP); return addr.readU32()===ARM64_NOP; }catch(e){ return false; } }
function scanAndPatch(base,size){ var key=base.toString()+":"+size; if(scannedBases[key]) return; scannedBases[key]=1; var k=0,b=0; for(var i=4;i<size-4;i+=4){ try{ var w=base.add(i).readU32(),wS=w|0; if(w===0xD4000001){ var p=base.add(i-4).readU32()|0,nr=-1; if((p&MASK_MOVZW)===MOVZ_X8_BASE) nr=(p>>5)&0xFFFF; if((p&MASK_MOVZW)===MOVW_W8_BASE) nr=(p>>5)&0xFFFF; if(nr===93||nr===94||nr===129||nr===130||nr===131){if(patchNop(base.add(i)))k++;} } if((wS&BRK_MASK)===BRK_BASE&&w!==0){if(patchNop(base.add(i)))b++;} }catch(e){} } console.log("[SCAN] @"+base+" sz="+size+" kills="+k+" BRKs="+b); }
Interceptor.attach(libc.findExportByName("raise"),{ onEnter:function(a){ raiseCount++; console.log("[RAISE-"+raiseCount+"]"); a[0]=ptr(0); Thread.sleep(0.1); } });
var noopThread=new NativeCallback(function(a){ Thread.sleep(300); return ptr(0); },'pointer',['pointer']);
Interceptor.attach(libc.findExportByName("pthread_create"),{ onEnter:function(a){ try{ var r=Process.findRangeByAddress(a[2]); if(r&&!r.file){ console.log("[pthread] ANON sz="+r.size); if(r.size>100000&&ijiami_base.equals(ptr(0))){ ijiami_base=r.base; ijiami_end=r.base.add(r.size); console.log("[iJiami] base="+ijiami_base); } scanAndPatch(r.base,r.size); a[2]=noopThread; } }catch(e){} } });
Interceptor.replace(libc.findExportByName("tgkill"),new NativeCallback(function(a,b,c){ return 0;},'int',['int','int','int']));
Interceptor.replace(libc.findExportByName("kill"),new NativeCallback(function(a,b){ return 0;},'int',['int','int']));
Interceptor.replace(libc.findExportByName("pthread_kill"),new NativeCallback(function(a,b){ return 0;},'int',['pointer','int']));
["abort","_exit","exit"].forEach(function(n){var fn=libc.findExportByName(n);if(fn)Interceptor.replace(fn,new NativeCallback(function(c){},'void',['int']));});
var excLog={}; Process.setExceptionHandler(function(d){ if(!d.context)return false; var pc=d.context.pc,lr=d.context.lr; if(isInIjiami(pc)){try{Memory.protect(pc,4,'rwx');pc.writeU32(ARM64_NOP);}catch(e){} d.context.pc=pc.add(4);return true;} if(pc.equals(ptr(0))&&isInIjiami(lr)){ d.context.pc=lr;return true;} return false; });
[0x54b318, 0x40f808].forEach(function(off){
    try{ Interceptor.attach(libart.base.add(off),{ onEnter:function(a){ var cnt=a[3].toInt32(); for(var i=0;i<Math.min(cnt,20);i++){ try{ var e=a[2].add(i*24); console.log("[RegN] "+e.readPointer().readCString()); }catch(e2){} } }}); }catch(e){}
});

// === ANTI-EMULATOR: __system_property_get spoofing ===
var FAKE_PROPS = {
    "ro.kernel.qemu":         "0",
    "ro.kernel.qemu.gles":    "0",
    "ro.boot.qemu":           "0",
    "ro.hardware":            "qcom",
    "ro.hardware.egl":        "adreno",
    "ro.hardware.vulkan":     "pastel",
    "ro.boot.hardware":       "qcom",
    "ro.product.model":       "Pixel 6",
    "ro.product.device":      "oriole",
    "ro.product.board":       "oriole",
    "ro.product.manufacturer":"Google",
    "ro.product.brand":       "google",
    "ro.product.name":        "oriole",
    "ro.build.tags":          "release-keys",
    "ro.build.type":          "user",
    "ro.debuggable":          "0",
    "ro.secure":              "1",
    "qemu.hw.mainkeys":       ""
};
var propGetFn = libc.findExportByName("__system_property_get");
if (propGetFn) {
    Interceptor.attach(propGetFn, {
        onEnter: function(a) {
            this.name = a[0].readCString();
            this.buf  = a[1];
        },
        onLeave: function(retval) {
            var fake = FAKE_PROPS[this.name];
            if (fake !== undefined) {
                console.log("[PROP] " + this.name + " => '" + fake + "'");
                this.buf.writeUtf8String(fake);
                retval.replace(ptr(fake.length > 0 ? fake.length : 0));
            }
        }
    });
    console.log("[*] __system_property_get hookeado (" + propGetFn + ")");
} else {
    console.log("[!] __system_property_get NO encontrado");
}

// === ANTI-EMULATOR: bloquear open() para archivos QEMU ===
var BLOCK_PATHS = ["/proc/tty/drivers", "/dev/socket/qemud", "/sys/qemu_trace", "/sys/qemu_pipe"];
function hookOpenFn(fnName) {
    var fn = libc.findExportByName(fnName) || libc.findExportByName(fnName + "64");
    if (!fn) return;
    var isOpenAt = (fnName === "openat");
    Interceptor.attach(fn, {
        onEnter: function(a) {
            var idx = isOpenAt ? 1 : 0;
            try {
                var path = a[idx].readCString();
                for (var i = 0; i < BLOCK_PATHS.length; i++) {
                    if (path && path.indexOf(BLOCK_PATHS[i]) >= 0) {
                        console.log("[OPEN-BLOCK] " + path);
                        a[idx] = Memory.allocUtf8String("/dev/null");
                        break;
                    }
                }
            } catch(e) {}
        }
    });
}
hookOpenFn("openat");
hookOpenFn("open");

Java.perform(function(){
    console.log("[Java] OK");
    try{ Java.use("java.lang.System").exit.implementation=function(s){console.log("[exit] BLOCKED="+s);};}catch(e){}
});
console.log("[*] v62 listo");

// === ANTI-EMULATOR: filtrar /proc/self/maps para remover strings de emulador ===
var maps_fds = {};
var FILTER_MAPS = ["ranchu", "goldfish", "_enc.so", "qemu_hw_prop", "vbox", "genymotion"];

// Trackear openat de /proc/*/maps
var _openat = libc.findExportByName("openat");
if (_openat) {
    Interceptor.attach(_openat, {
        onEnter: function(a) {
            try {
                var path = a[1].readCString();
                if (path && (path === "/proc/self/maps" || /\/proc\/\d+\/maps$/.test(path))) {
                    this.is_maps = true;
                    console.log("[MAPS-OPEN] " + path);
                }
            } catch(e) {}
        },
        onLeave: function(retval) {
            if (this.is_maps) {
                var fd = retval.toInt32();
                if (fd >= 0) { maps_fds[fd] = 1; console.log("[MAPS-FD] " + fd); }
            }
        }
    });
}

// Hookear read() para filtrar contenido de maps
var _read = libc.findExportByName("read");
if (_read) {
    Interceptor.attach(_read, {
        onEnter: function(a) {
            this.fd    = a[0].toInt32();
            this.buf   = a[1];
            this.count = a[2].toInt32();
        },
        onLeave: function(retval) {
            if (!maps_fds[this.fd]) return;
            var len = retval.toInt32();
            if (len <= 0) return;
            try {
                var content = this.buf.readUtf8String(len);
                var lines = content.split('\n');
                var filtered = [];
                var removed = 0;
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i];
                    var block = false;
                    for (var j = 0; j < FILTER_MAPS.length; j++) {
                        if (line.indexOf(FILTER_MAPS[j]) >= 0) { block = true; removed++; break; }
                    }
                    if (!block) filtered.push(line);
                }
                if (removed > 0) {
                    var cleaned = filtered.join('\n');
                    this.buf.writeUtf8String(cleaned);
                    retval.replace(ptr(cleaned.length));
                    console.log("[MAPS-FILTER] -" + removed + " lines emulador");
                }
            } catch(e) { console.log("[MAPS-ERR] " + e); }
        }
    });
}

// Cerrar fd tracking
Interceptor.attach(libc.findExportByName("close"), {
    onEnter: function(a) { delete maps_fds[a[0].toInt32()]; }
});

console.log("[*] maps filter instalado");
