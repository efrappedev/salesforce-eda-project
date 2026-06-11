console.log("[*] bypass_v65 — kills + Java trace (WelcomeActivity)");
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
Process.setExceptionHandler(function(d){ if(!d.context)return false; var pc=d.context.pc,lr=d.context.lr; if(isInIjiami(pc)){try{Memory.protect(pc,4,'rwx');pc.writeU32(ARM64_NOP);}catch(e){} d.context.pc=pc.add(4);return true;} if(pc.equals(ptr(0))&&isInIjiami(lr)){ d.context.pc=lr;return true;} return false; });
[0x54b318, 0x40f808].forEach(function(off){
    try{ Interceptor.attach(libart.base.add(off),{ onEnter:function(a){ var cnt=a[3].toInt32(); for(var i=0;i<Math.min(cnt,20);i++){ try{ var e=a[2].add(i*24); console.log("[RegN] "+e.readPointer().readCString()); }catch(e2){} } }}); }catch(e){}
});

// === JAVA TRACE ===
Java.perform(function() {
    console.log("[Java] perform OK");

    // Hook Activity lifecycle
    try {
        var Activity = Java.use("android.app.Activity");
        Activity.onCreate.overload("android.os.Bundle").implementation = function(b) {
            console.log("[ACT] onCreate: " + this.$className);
            this.onCreate(b);
            console.log("[ACT] onCreate DONE: " + this.$className);
        };
        Activity.onStart.implementation = function() {
            console.log("[ACT] onStart: " + this.$className);
            this.onStart();
        };
        Activity.onResume.implementation = function() {
            console.log("[ACT] onResume: " + this.$className);
            this.onResume();
        };
        console.log("[Java] Activity hooks OK");
    } catch(e) { console.log("[Java] Activity hook ERR: " + e); }

    // Hook URL connections
    try {
        var URL = Java.use("java.net.URL");
        URL.openConnection.overload().implementation = function() {
            console.log("[NET] URL.openConnection: " + this.toString());
            return this.openConnection();
        };
        console.log("[Java] URL hook OK");
    } catch(e) { console.log("[Java] URL ERR: " + e); }

    // Hook OkHttp
    setTimeout(function() {
        Java.perform(function() {
            try {
                var RealCall = Java.use("okhttp3.internal.connection.RealCall");
                RealCall.execute.implementation = function() {
                    console.log("[OKHTTP] execute: " + this.request().url().toString());
                    return this.execute();
                };
                console.log("[Java] OkHttp RealCall hook OK");
            } catch(e) { console.log("[Java] OkHttp ERR: " + e); }

            // Hook Thread.start
            try {
                var Thread = Java.use("java.lang.Thread");
                Thread.start.implementation = function() {
                    console.log("[THREAD] start: " + this.getName());
                    this.start();
                };
                console.log("[Java] Thread hook OK");
            } catch(e) {}

            // Listar clases WelcomeActivity-related que ya estan cargadas
            try {
                Java.enumerateClassLoaders({
                    onMatch: function(loader) {
                        try {
                            var wa = Java.ClassFactory.get(loader).use("com.interactive.brasiliptv.ui.activity.WelcomeActivity");
                            console.log("[CL] WelcomeActivity encontrada en ClassLoader: " + loader.$className);
                        } catch(e2) {}
                    },
                    onComplete: function() { console.log("[CL] enumeration done"); }
                });
            } catch(e) { console.log("[CL] ERR: " + e); }
        });
    }, 3000);

    // Bloquear System.exit
    try{ Java.use("java.lang.System").exit.implementation=function(s){console.log("[exit] BLOCKED="+s);};}catch(e){}
});
console.log("[*] v65 listo");
