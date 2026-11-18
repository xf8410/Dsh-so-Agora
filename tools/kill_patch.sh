#!/bin/bash
# 追加 kill/tgkill 拦截（延后安装、校验 trampoline、hook 内不打日志）
set -e
ROOT="${1:-hz}"

cat >> "$ROOT/src/android/main.rs" <<'RSEOF'

static ORIG_KILL: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static ORIG_TGKILL: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

extern "C" fn kill_hook(pid: i32, sig: i32) -> i32 {
    if sig == 9 {
        let me = std::process::id() as i32;
        if pid == me || pid == -me || pid == 0 { return 0; }
    }
    let p = ORIG_KILL.load(std::sync::atomic::Ordering::Relaxed);
    if p == 0 { return -1; }
    let f: extern "C" fn(i32, i32) -> i32 = unsafe { std::mem::transmute(p) };
    f(pid, sig)
}

extern "C" fn tgkill_hook(tgid: i32, tid: i32, sig: i32) -> i32 {
    if sig == 9 {
        let me = std::process::id() as i32;
        if tgid == me { return 0; }
    }
    let p = ORIG_TGKILL.load(std::sync::atomic::Ordering::Relaxed);
    if p == 0 { return -1; }
    let f: extern "C" fn(i32, i32, i32) -> i32 = unsafe { std::mem::transmute(p) };
    f(tgid, tid, sig)
}

pub fn install_kill_hooks() {
    unsafe {
        let h = Hachimi::instance();
        let k = crate::symbols_impl::dlsym(1 as *mut std::ffi::c_void, "kill");
        if k != 0 {
            if h.interceptor.hook(k, kill_hook as usize).is_ok() {
                let tr = h.interceptor.get_trampoline_addr(k);
                if tr != 0 {
                    ORIG_KILL.store(tr, std::sync::atomic::Ordering::Relaxed);
                    log::info!("kill hook ok {:#x} tr={:#x}", k, tr);
                }
            }
        }
        let t = crate::symbols_impl::dlsym(1 as *mut std::ffi::c_void, "tgkill");
        if t != 0 {
            if h.interceptor.hook(t, tgkill_hook as usize).is_ok() {
                let tr = h.interceptor.get_trampoline_addr(t);
                if tr != 0 {
                    ORIG_TGKILL.store(tr, std::sync::atomic::Ordering::Relaxed);
                    log::info!("tgkill hook ok {:#x} tr={:#x}", t, tr);
                }
            }
        }
    }
}
RSEOF

python3 - "$ROOT" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
m = root / "src/android/main.rs"
t = m.read_text(encoding="utf-8")
needle = "crate::symbols_impl::warmup();"
if "install_kill_hooks();" not in t:
    t = t.replace(needle, needle + "\n                install_kill_hooks();", 1)
    m.write_text(t, encoding="utf-8")
    print("kill hooks call inserted")
else:
    print("kill hooks already present")
PY