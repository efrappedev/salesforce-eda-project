// bypass_v67 — SIN noopThread, diagnóstico completo de mecanismos de kill
// Objetivo: capturar EXACTAMENTE cómo el proceso intenta morir
console.log("[*] bypass_v67 — diagnóstico kill completo");

var libc = Process.findModuleByName("libc.so");
var libart = Process.findModuleByName("libart.so");
var raiseCount = 0;
var scannedBases = {};
var ijiami_base = ptr(0), ijiami_end = ptr(0);

function tid(){ return Process.getCurrentThreadId(); }

function isInIjiami(p){
    return !ijiami_base.equals(ptr(0)) && p.compare(ijiami_base)>=0 && p.compare(ijiami_end)<0;
}

var ARM64_NOP=0xD503201F;
var MOVZ_X8_BASE=(0xD2800008|0), MOVW_W8_BASE=(0x52800008|0), MASK_MOVZW=(0xFFE0001F|0);
var BRK_BASE=(0xD4200000|0), BRK_MASK=(0xFFE0001F|0);

function patchNop(addr){
    try{ Memory.protect(addr,4,'rwx'); addr.writeU32(ARM64_NOP); return addr.readU32()===ARM64_NOP; }catch(e){ return false; }
}
function scanAndPatch(base,size){
    var key=base.toString()+":"+size;
    if(scannedBases[key]) return;
    scannedBases[key]=1;
    var k=0,b=0;
    for(var i=4;i<size-4;i+=4){
        try{
            var w=base.add(i).readU32(),wS=w|0;
            if(w===0xD4000001){
                var p=base.add(i-4).readU32()|0,nr=-1;
                if((p&MASK_MOVZW)===MOVZ_X8_BASE) nr=(p>>5)&0xFFFF;
                if((p&MASK_MOVZW)===MOVW_W8_BASE) nr=(p>>5)&0xFFFF;
                if(nr===93||nr===94||nr===129||nr===130||nr===131){if(patchNop(base.add(i)))k++;}
            }
            if((wS&BRK_MASK)===BRK_BASE&&w!==0){if(patchNop(base.add(i)))b++;}
        }catch(e){}
    }
    console.log("[SCAN] @"+base+" sz="+size+" kills="+k+" BRKs="+b);
}

// ---- RAISE ----
Interceptor.attach(libc.findExportByName("raise"),{
    onEnter:function(a){
        raiseCount++;
        console.log("[RAISE-"+raiseCount+"] sig="+a[0].toInt32()+" tid="+tid());
        a[0]=ptr(0);
        Thread.sleep(0.05);
    }
});

// ---- pthread_create SIN noopThread ----
Interceptor.attach(libc.findExportByName("pthread_create"),{
    onEnter:function(a){
        try{
            var r=Process.findRangeByAddress(a[2]);
            if(r&&!r.file){
                console.log("[pthread] ANON sz="+r.size+" fn="+a[2]+" tid="+tid());
                if(r.size>100000&&ijiami_base.equals(ptr(0))){
                    ijiami_base=r.base; ijiami_end=r.base.add(r.size);
                    console.log("[iJiami] base="+ijiami_base);
                }
                scanAndPatch(r.base,r.size);
                // NO noopThread — dejar correr
            }
        }catch(e){}
    }
});

// ---- pthread_exit — ver cuando terminan los threads ----
var pthread_exit_fn = libc.findExportByName("pthread_exit");
if(pthread_exit_fn){
    Interceptor.attach(pthread_exit_fn,{
        onEnter:function(a){
            console.log("[pthread_exit] tid="+tid()+" retval="+a[0]);
        }
    });
}

// ---- KILL FUNCTIONS ----
Interceptor.replace(libc.findExportByName("tgkill"),
    new NativeCallback(function(a,b,c){
        console.log("[tgkill] pid="+a+" tid="+b+" sig="+c+" caller_tid="+tid());
        return 0;
    },'int',['int','int','int']));

Interceptor.replace(libc.findExportByName("kill"),
    new NativeCallback(function(a,b){
        console.log("[kill] pid="+a+" sig="+b+" caller_tid="+tid());
        return 0;
    },'int',['int','int']));

Interceptor.replace(libc.findExportByName("pthread_kill"),
    new NativeCallback(function(a,b){
        console.log("[pthread_kill] sig="+b+" caller_tid="+tid());
        return 0;
    },'int',['pointer','int']));

// ---- ABORT/EXIT ----
["abort","_exit","exit"].forEach(function(n){
    var fn=libc.findExportByName(n);
    if(fn) Interceptor.replace(fn,new NativeCallback(function(c){
        console.log("["+n+"] code="+c+" tid="+tid());
    },'void',['int']));
});

// ---- SIGACTION — detectar instalacion de handlers de senal ----
var sigaction_fn = libc.findExportByName("sigaction") || libc.findExportByName("sigaction64");
if(sigaction_fn){
    Interceptor.attach(sigaction_fn,{
        onEnter:function(a){
            var sig=a[0].toInt32();
            if(sig!==0 && sig!==28 && sig!==14) // ignorar SIGWINCH(28), SIGALRM(14)
                console.log("[sigaction] sig="+sig+" tid="+tid());
        }
    });
}

// ---- ALARM/SETITIMER — timers que matan el proceso ----
var alarm_fn = libc.findExportByName("alarm");
if(alarm_fn){
    Interceptor.attach(alarm_fn,{
        onEnter:function(a){ console.log("[alarm] secs="+a[0].toInt32()+" tid="+tid()); }
    });
}
var setitimer_fn = libc.findExportByName("setitimer");
if(setitimer_fn){
    Interceptor.attach(setitimer_fn,{
        onEnter:function(a){ console.log("[setitimer] which="+a[0].toInt32()+" tid="+tid()); }
    });
}

// ---- MPROTECT — cambios de permisos de memoria (manipulacion de codigo) ----
var mprotect_fn = libc.findExportByName("mprotect");
if(mprotect_fn){
    Interceptor.attach(mprotect_fn,{
        onEnter:function(a){
            var prot=a[2].toInt32();
            // Solo loguear si hace algo ejecutable (posible inyeccion de codigo)
            if(prot&4) console.log("[mprotect] addr="+a[0]+" sz="+a[1].toInt32()+" prot="+prot+" tid="+tid());
        }
    });
}

// ---- Exception handler ----
Process.setExceptionHandler(function(d){
    if(!d.context)return false;
    var pc=d.context.pc,lr=d.context.lr;
    if(isInIjiami(pc)){
        try{Memory.protect(pc,4,'rwx');pc.writeU32(ARM64_NOP);}catch(e){}
        d.context.pc=pc.add(4);
        return true;
    }
    if(pc.equals(ptr(0))&&isInIjiami(lr)){
        d.context.pc=lr;
        return true;
    }
    console.log("[EXC] pc="+pc+" lr="+lr+" sig="+d.type);
    return false;
});

// ---- RegisterNatives ----
[0x54b318, 0x40f808].forEach(function(off){
    try{
        Interceptor.attach(libart.base.add(off),{
            onEnter:function(a){
                var cnt=a[3].toInt32();
                for(var i=0;i<Math.min(cnt,20);i++){
                    try{ var e=a[2].add(i*24); console.log("[RegN] "+e.readPointer().readCString()); }catch(e2){}
                }
            }
        });
    }catch(e){}
});

console.log("[*] v67 listo — sin noopThread, diagnostico completo");
