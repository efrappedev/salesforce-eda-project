// v58 — fix null-call trap: BLR Xn donde Xn=0 → PC=0x0
// v57: EXC OUT access-violation @ 0x0 (NOT iJiami) → return false → crash
// Fix: si PC=0x0 y LR está dentro iJiami → simular return (PC=LR)
console.log("[*] v58 inicio");
var libc = Process.findModuleByName("libc.so");
var raiseCount = 0;
var scannedBases = {};

var ijiami_base = ptr(0);
var ijiami_end  = ptr(0);

function isInIjiami(p) {
    return !ijiami_base.equals(ptr(0)) &&
           p.compare(ijiami_base) >= 0 &&
           p.compare(ijiami_end)  < 0;
}

var ARM64_NOP    = 0xD503201F;
var MOVZ_X8_BASE = (0xD2800008 | 0);
var MOVW_W8_BASE = (0x52800008 | 0);
var MASK_MOVZW   = (0xFFE0001F | 0);
var BRK_BASE     = (0xD4200000 | 0);
var BRK_MASK     = (0xFFE0001F | 0);

function patchNop(addr) {
    try { Memory.protect(addr, 4, 'rwx'); addr.writeU32(ARM64_NOP); return addr.readU32() === ARM64_NOP; }
    catch(e) { return false; }
}

function scanAndPatch(base, size) {
    var key = base.toString() + ":" + size;
    if (scannedBases[key]) return [0, 0];
    scannedBases[key] = 1;
    var kills = 0, brks = 0;
    for (var i = 4; i < size - 4; i += 4) {
        try {
            var w = base.add(i).readU32();
            var wS = w | 0;
            if (w === 0xD4000001) {
                var prev = base.add(i-4).readU32() | 0;
                var nr = -1;
                if ((prev & MASK_MOVZW) === MOVZ_X8_BASE) nr = (prev >> 5) & 0xFFFF;
                if ((prev & MASK_MOVZW) === MOVW_W8_BASE) nr = (prev >> 5) & 0xFFFF;
                if (nr === 93 || nr === 94 || nr === 129 || nr === 130 || nr === 131) {
                    if (patchNop(base.add(i))) kills++;
                }
            }
            if ((wS & BRK_MASK) === BRK_BASE && w !== 0) {
                if (patchNop(base.add(i))) brks++;
            }
        } catch(e) {}
    }
    console.log("[SCAN] @" + base + " sz=" + size + " kills=" + kills + " BRKs=" + brks);
    return [kills, brks];
}

Interceptor.attach(libc.findExportByName("raise"), {
    onEnter: function(a) {
        raiseCount++;
        console.log("[RAISE-" + raiseCount + "] sig=" + a[0].toInt32());
        a[0] = ptr(0);
        Thread.sleep(0.1);
    }
});

var noopThread = new NativeCallback(function(a) {
    console.log("[ANON THREAD] no-op tid=" + Process.getCurrentThreadId());
    Thread.sleep(300);
    return ptr(0);
}, 'pointer', ['pointer']);

Interceptor.attach(libc.findExportByName("pthread_create"), {
    onEnter: function(a) {
        var fn = a[2];
        try {
            var range = Process.findRangeByAddress(fn);
            if (range && !range.file) {
                console.log("[pthread_create] ANON @" + range.base + " sz=" + range.size);
                if (range.size > 100000 && ijiami_base.equals(ptr(0))) {
                    ijiami_base = range.base;
                    ijiami_end  = range.base.add(range.size);
                    console.log("[iJiami] base=" + ijiami_base + " end=" + ijiami_end);
                }
                scanAndPatch(range.base, range.size);
                a[2] = noopThread;
            }
        } catch(e) {}
    }
});

var tracerFds = {};
Interceptor.attach(libc.findExportByName("openat"), {
    onEnter: function(a) { try { var p=a[1].readUtf8String(); if(p&&p.indexOf("status")>=0) this.p=p; } catch(e) {} },
    onLeave: function(ret) { if(this.p){ var fd=ret.toInt32(); if(fd>=0) tracerFds[fd]=1; } }
});
Interceptor.attach(libc.findExportByName("read"), {
    onEnter: function(a) { this.fd=a[0].toInt32(); this.buf=a[1]; this.ok=!!tracerFds[this.fd]; },
    onLeave: function(ret) {
        if(!this.ok||ret.toInt32()<=0) return;
        try {
            var s=this.buf.readUtf8String(ret.toInt32());
            if(s.indexOf("TracerPid")>=0){ var m=s.match(/TracerPid:\s*(\d+)/); if(m&&m[1]!=='0'){ Memory.writeUtf8String(this.buf,s.replace(/TracerPid:\s*\d+/,"TracerPid:\t0")); console.log("[status] TracerPid→0"); }}
        } catch(e) {}
    }
});
Interceptor.attach(libc.findExportByName("close"),{onEnter:function(a){delete tracerFds[a[0].toInt32()];}});

Interceptor.replace(libc.findExportByName("tgkill"),new NativeCallback(function(a,b,c){ if(c!==0) console.log("[tgkill] BLOCKED sig="+c); return 0;},'int',['int','int','int']));
Interceptor.replace(libc.findExportByName("kill"),new NativeCallback(function(a,b){ if(b!==0) console.log("[kill] BLOCKED pid="+a+" sig="+b); return 0;},'int',['int','int']));
Interceptor.replace(libc.findExportByName("pthread_kill"),new NativeCallback(function(a,b){ if(b!==0) console.log("[pthread_kill] BLOCKED sig="+b); return 0;},'int',['pointer','int']));
["abort","_exit","exit"].forEach(function(n){ var fn=libc.findExportByName(n); if(fn) Interceptor.replace(fn,new NativeCallback(function(c){ console.log("["+n+"] BLOCKED="+c);},'void',['int']));});
Interceptor.attach(libc.findExportByName("syscall"),{onEnter:function(a){ var nr=a[0].toInt32(); if(nr===93||nr===94||nr===129||nr===130||nr===131){ console.log("[syscall] KILL nr="+nr); a[0]=ptr(172);}}});

Java.perform(function() {
    try { Java.use("java.lang.System").exit.implementation = function(s) { console.log("[System.exit] BLOCKED="+s); }; } catch(e) {}
    try { Java.use("s.h.e.l.l.N").l.implementation = function(a,b) { console.log("[N.l]→true"); return true; }; } catch(e) { console.log("[N.l ERR] "+e.message); }
    console.log("[Java] OK");
});

var excLog = {};
Process.setExceptionHandler(function(d) {
    if (!d.context) return false;
    var type = d.type;
    var pc  = d.context.pc;
    var lr  = d.context.lr;

    // Caso 1: PC dentro iJiami → NOP + avanzar
    if (isInIjiami(pc)) {
        var key = type + "@" + pc;
        if (!excLog[key]) excLog[key] = 0;
        excLog[key]++;
        if (excLog[key] <= 2) console.log("[EXC#"+excLog[key]+"] "+type+" @ "+pc+" (iJiami) → NOP+skip");
        try { Memory.protect(pc, 4, 'rwx'); pc.writeU32(ARM64_NOP); } catch(e) {}
        d.context.pc = pc.add(4);
        return true;
    }

    // Caso 2: PC=0x0 = null-call trap desde iJiami (BLR Xn donde Xn=0)
    // LR apunta a la instrucción SIGUIENTE al BLR → simular return
    if (pc.equals(ptr(0)) && isInIjiami(lr)) {
        var key2 = "nullcall@" + lr;
        if (!excLog[key2]) excLog[key2] = 0;
        excLog[key2]++;
        if (excLog[key2] <= 2) console.log("[NULL-CALL#"+excLog[key2]+"] PC=0x0 LR="+lr+" → return");
        d.context.pc = lr;
        return true;
    }

    // Caso 3: fuera de iJiami — NO avanzar, loguear solo una vez
    var outKey = type + "@" + pc;
    if (!excLog[outKey]) {
        excLog[outKey] = 1;
        console.log("[EXC OUT] " + type + " @ " + pc + " LR=" + lr);
    }
    return false;
});

console.log("[*] v58 listo");
