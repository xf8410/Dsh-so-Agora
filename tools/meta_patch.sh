#!/bin/bash
# 在 Hachimi 源码上应用：symbols 自解析 + metadata hook(meta-only) + late_load/poll + sendSignal 拦截
set -e
ROOT="${1:-hz}"

cat > "$ROOT/src/android/symbols_impl.rs" <<'RSEOF'
use std::{collections::HashMap, ffi::c_void, sync::OnceLock};
use std::os::unix::fs::FileExt;

static CACHE: OnceLock<HashMap<String, usize>> = OnceLock::new();
static EMPTY: OnceLock<HashMap<String, usize>> = OnceLock::new();
thread_local! { static ATTACHED: std::cell::Cell<bool> = std::cell::Cell::new(false); }

fn u16le(b: &[u8], o: usize) -> u16 { u16::from_le_bytes([b[o], b[o + 1]]) }
fn u32le(b: &[u8], o: usize) -> u32 { u32::from_le_bytes([b[o], b[o+1], b[o+2], b[o+3]]) }
fn u64le(b: &[u8], o: usize) -> u64 { u64::from_le_bytes([b[o],b[o+1],b[o+2],b[o+3],b[o+4],b[o+5],b[o+6],b[o+7]]) }

fn il2cpp_base() -> Option<usize> {
    let maps = std::fs::read_to_string("/proc/self/maps").ok()?;
    let mut e = usize::MAX; let mut a0 = usize::MAX;
    for line in maps.lines() {
        if !line.contains("libil2cpp.so") { continue; }
        let mut it = line.split_whitespace();
        let rng = it.next().unwrap_or(""); let perms = it.next().unwrap_or("");
        let Ok(a) = usize::from_str_radix(rng.split('-').next().unwrap_or(""), 16) else { continue };
        if a < a0 { a0 = a; }
        if perms.contains('x') && a < e { e = a; }
    }
    if e != usize::MAX { Some(e) } else if a0 != usize::MAX { Some(a0) } else { None }
}

fn build_cache() -> HashMap<String, usize> {
    let mut out = HashMap::new();
    let Some(base) = il2cpp_base() else { return out };
    let Ok(f) = std::fs::File::open("/proc/self/mem") else { return out };
    let adj = |v: u64| -> u64 { if v != 0 && (v as usize) < base { (base + v as usize) as u64 } else { v } };
    let mut hdr = [0u8; 64];
    if f.read_exact_at(&mut hdr, base as u64).is_err() { return out; }
    if &hdr[0..4] != b"\x7fELF" { return out; }
    let phoff = u64le(&hdr, 0x20) as usize;
    let phent = u16le(&hdr, 0x36) as usize;
    let phnum = u16le(&hdr, 0x38) as usize;
    let mut dynv: usize = 0;
    for i in 0..phnum {
        let mut ph = [0u8; 56];
        if f.read_exact_at(&mut ph, (base + phoff + i * phent) as u64).is_err() { break; }
        if u32le(&ph, 0) == 2 { dynv = u64le(&ph, 0x10) as usize; }
    }
    if dynv == 0 { return out; }
    let (mut st, mut strt, mut hash) = (0u64, 0u64, 0u64);
    for i in 0..512 {
        let mut d = [0u8; 16];
        if f.read_exact_at(&mut d, (base + dynv + i * 16) as u64).is_err() { break; }
        let (tag, val) = (u64le(&d, 0), u64le(&d, 8));
        if tag == 0 { break; }
        match tag { 6 => st = val, 5 => strt = val, 4 => hash = val, _ => {} }
    }
    if st == 0 || strt == 0 { return out; }
    let (st, strt, hash) = (adj(st), adj(strt), adj(hash));
    let mut count: usize = 0;
    if hash != 0 {
        let mut hb = [0u8; 8];
        if f.read_exact_at(&mut hb, hash + 4).is_ok() { count = u32le(&hb, 0) as usize; }
    }
    if count == 0 || count > 500000 {
        count = if strt > st { ((strt - st) / 24) as usize } else { 20000 };
    }
    let mut n = 0usize;
    for i in 0..count {
        let mut s = [0u8; 24];
        if f.read_exact_at(&mut s, st + (i as u64) * 24).is_err() { break; }
        let off = u32le(&s, 0) as u64; let val = u64le(&s, 8);
        if val == 0 { continue; }
        let mut nb = [0u8; 256];
        if f.read_exact_at(&mut nb, strt + off).is_err() { continue; }
        let end = nb.iter().position(|&c| c == 0).unwrap_or(nb.len());
        if end == 0 { continue; }
        if let Ok(nm) = std::str::from_utf8(&nb[..end]) { out.insert(nm.to_string(), base + val as usize); n += 1; }
    }
    if n > 0 { log::info!("symbols: exec_base={:#x} inserted={}", base, n); }
    out
}

fn cache() -> &'static HashMap<String, usize> {
    if let Some(c) = CACHE.get() { return c; }
    let m = build_cache();
    if !m.is_empty() { let _ = CACHE.set(m); }
    CACHE.get().unwrap_or_else(|| EMPTY.get_or_init(HashMap::new))
}

pub fn warmup() {
    for i in 0..120 {
        let m = build_cache();
        if !m.is_empty() { let n = m.len(); let _ = CACHE.set(m); log::info!("symbols: warmup done {} (try {})", n, i); return; }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    log::warn!("symbols: warmup gave up");
}

unsafe fn ensure_attached(c: &HashMap<String, usize>) {
    if ATTACHED.with(|x| x.get()) { return; }
    let (Some(&dg), Some(&ta)) = (c.get("il2cpp_domain_get"), c.get("il2cpp_thread_attach")) else { return };
    let domain_get: extern "C" fn() -> *mut c_void = std::mem::transmute(dg);
    let thread_attach: extern "C" fn(*mut c_void) -> *mut c_void = std::mem::transmute(ta);
    let dom = domain_get();
    if !dom.is_null() { thread_attach(dom); log::info!("symbols: attached"); ATTACHED.with(|x| x.set(true)); }
}

pub unsafe fn dlsym(handle: *mut c_void, name: &str) -> usize {
    let c = cache();
    ensure_attached(c);
    if let Some(&a) = c.get(name) { return a; }
    let Ok(cs) = std::ffi::CString::new(name) else { return 0 };
    let p = libc::dlsym(std::ptr::null_mut(), cs.as_ptr()) as usize;
    if p != 0 { return p; }
    if handle.is_null() || handle as usize == 1 { return 0; }
    libc::dlsym(handle, cs.as_ptr()) as usize
}
RSEOF

cat >> "$ROOT/src/android/main.rs" <<'RSEOF'

static ORIG_SEND_SIGNAL: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

extern "C" fn send_signal_hook(_env: *mut std::ffi::c_void, _clazz: *mut std::ffi::c_void, pid: i32, sig: i32) -> i32 {
    if sig == 9 {
        let me = std::process::id() as i32;
        if pid == me || pid == -me || pid == 0 { return 0; }
    }
    let p = ORIG_SEND_SIGNAL.load(std::sync::atomic::Ordering::Relaxed);
    if p == 0 { return -1; }
    let f: extern "C" fn(*mut std::ffi::c_void, *mut std::ffi::c_void, i32, i32) -> i32 = unsafe { std::mem::transmute(p) };
    f(_env, _clazz, pid, sig)
}

pub fn install_send_signal_hook() {
    unsafe {
        let addr = crate::symbols_impl::dlsym(1 as *mut std::ffi::c_void, "android_os_Process_sendSignal");
        if addr == 0 { log::warn!("sendSignal symbol not found"); return; }
        let h = Hachimi::instance();
        match h.interceptor.hook(addr, send_signal_hook as usize) {
            Ok(_) => {
                let tr = h.interceptor.get_trampoline_addr(addr);
                ORIG_SEND_SIGNAL.store(tr, std::sync::atomic::Ordering::Relaxed);
                log::info!("sendSignal hook ok addr={:#x}", addr);
            }
            Err(e) => log::warn!("sendSignal hook failed: {}", e),
        }
    }
}
RSEOF

python3 - "$ROOT" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])

sy = root / "src/il2cpp/symbols.rs"
s = sy.read_text(encoding="utf-8")
if "META_MAP" not in s:
    s = s.replace("use crate::core::Hachimi;",
        "use crate::core::Hachimi;\n"
        "pub static META_MAP: once_cell::sync::Lazy<std::sync::Mutex<std::collections::HashMap<usize, usize>>> = "
        "once_cell::sync::Lazy::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));\n", 1)
    s = s.replace("    if let Ok(method) = res {\n        unsafe { (*method).methodPointer }\n    }",
        "    if let Ok(method) = res {\n        unsafe {\n"
        "            let p = (*method).methodPointer as usize;\n"
        "            if p != 0 { META_MAP.lock().unwrap().insert(p, method as usize); }\n"
        "            p\n        }\n    }")
    sy.write_text(s, encoding="utf-8")
    with open(sy, "a", encoding="utf-8") as f:
        f.write("\n\npub fn method_info_of(addr: usize) -> Option<usize> {\n"
                "    META_MAP.lock().unwrap().get(&addr).copied()\n}\n\n"
                "pub unsafe fn patch_method_pointer(mi_addr: usize, new_fn: usize) -> Option<usize> {\n"
                "    let mi = mi_addr as *mut MethodInfo;\n"
                "    if mi.is_null() { return None; }\n"
                "    let old = (*mi).methodPointer as usize;\n"
                "    (*mi).methodPointer = new_fn;\n"
                "    Some(old)\n}\n")

hm = root / "src/il2cpp/hook/mod.rs"
h = hm.read_text(encoding="utf-8")
old_macro = ("            if ($orig != 0) {\n"
             "                let res = hachimi.interceptor.hook($orig as usize, $hook as usize);\n"
             "                if let Err(e) = res {\n                    error!(\"{}\", e);\n                }\n"
             "            }")
new_macro = ("            if ($orig != 0) {\n"
             "                let mut done = false;\n"
             "                if let Some(mi) = crate::il2cpp::symbols::method_info_of($orig as usize) {\n"
             "                    if let Some(old) = unsafe { crate::il2cpp::symbols::patch_method_pointer(mi, $hook as usize) } {\n"
             "                        crate::core::interceptor::register_meta_orig($hook as usize, old);\n"
             "                        info!(\"meta_hook!: {}\", stringify!($hook));\n"
             "                        done = true;\n                    }\n                }\n"
             "                if !done {\n"
             "                    warn!(\"skip (no meta): {}\", stringify!($hook));\n"
             "                }\n            }")
if old_macro in h:
    hm.write_text(h.replace(old_macro, new_macro, 1), encoding="utf-8")

ic = root / "src/core/interceptor.rs"
c = ic.read_text(encoding="utf-8")
if "register_meta_orig" not in c:
    c = c.replace("macro_rules! get_orig_fn {",
        "static META_ORIG: once_cell::sync::Lazy<std::sync::Mutex<std::collections::HashMap<usize, usize>>> =\n"
        "    once_cell::sync::Lazy::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));\n"
        "pub fn register_meta_orig(hook: usize, orig: usize) { META_ORIG.lock().unwrap().insert(hook, orig); }\n"
        "pub fn get_orig_addr(hook: usize) -> usize {\n"
        "    if let Some(&a) = META_ORIG.lock().unwrap().get(&hook) { return a; }\n"
        "    crate::core::Hachimi::instance().interceptor.get_trampoline_addr(hook)\n}\n\n"
        "macro_rules! get_orig_fn {", 1)
    c = c.replace("        unsafe { std::mem::transmute::<usize, $type>(crate::core::Hachimi::instance().interceptor.get_trampoline_addr($hook as usize)) }",
                  "        unsafe { std::mem::transmute::<usize, $type>(crate::core::interceptor::get_orig_addr($hook as usize)) }", 1)
    ic.write_text(c, encoding="utf-8")

cfg = root / "src/core/hachimi.rs"
t = cfg.read_text(encoding="utf-8")
if "poll_il2cpp" not in t:
    a = "    pub disable_gui_once: bool,"
    t = t.replace(a, a + ("\n    #[serde(default)]\n    pub late_load: bool,"
                          "\n    #[serde(default)]\n    pub disable_dlopen_hook: bool,"
                          "\n    #[serde(default)]\n    pub poll_il2cpp: bool,"), 1)
    cfg.write_text(t, encoding="utf-8")

hk = root / "src/android/hook.rs"
hf = hk.read_text(encoding="utf-8")
old = ('    info!("Hooking {} at {:#x}", dlopen_name, dlopen_orig);\n'
       '    hachimi.interceptor.hook(dlopen_orig, dlopen_hook)?;')
new = ('    if !hachimi.config.load().disable_dlopen_hook {\n'
       '        info!("Hooking {} at {:#x}", dlopen_name, dlopen_orig);\n'
       '        hachimi.interceptor.hook(dlopen_orig, dlopen_hook)?;\n'
       '    } else { info!("dlopen hook disabled by config"); }')
hk.write_text(hf.replace(old, new, 1), encoding="utf-8")

mn = root / "src/android/main.rs"
m = mn.read_text(encoding="utf-8")
old2 = '    info!("JNI_OnLoad");\n    orig_fn(vm, reserved)\n'
new2 = ('    info!("JNI_OnLoad");\n'
        '    install_send_signal_hook();\n'
        '    if Hachimi::instance().config.load().late_load {\n'
        '        if Hachimi::instance().config.load().poll_il2cpp {\n'
        '            std::thread::spawn(|| {\n'
        '                crate::symbols_impl::warmup();\n'
        '                let mut done = false;\n'
        '                for _ in 0..360 {\n'
        '                    std::thread::sleep(std::time::Duration::from_millis(500));\n'
        '                    let h = Hachimi::instance();\n'
        '                    let maps = std::fs::read_to_string("/proc/self/maps").unwrap_or_default();\n'
        '                    if !done && maps.lines().any(|l| l.contains("libil2cpp.so")) {\n'
        '                        h.on_dlopen("libil2cpp.so", 1);\n'
        '                        done = true;\n'
        '                        for _ in 0..6 { std::thread::sleep(std::time::Duration::from_millis(500)); }\n'
        '                        if h.on_dlopen("libcri_ware_unity.so", 1) { break; }\n'
        '                    }\n                }\n'
        '            });\n        }\n'
        '        return jni::sys::JNI_VERSION_1_6;\n    }\n'
        '    orig_fn(vm, reserved)\n')
if old2 in m:
    mn.write_text(m.replace(old2, new2, 1), encoding="utf-8")

print("meta_patch(+sendSignal) applied")
PY