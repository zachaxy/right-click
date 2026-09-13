use rustclick::{Engine, NATIVE, NativeFn};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::PathBuf,
    sync::{Mutex, OnceLock},
};
static ENGINE: OnceLock<Mutex<Engine>> = OnceLock::new();
fn dispatch(v: Value) -> Value {
    let result = std::panic::catch_unwind(|| ENGINE.get().unwrap().lock().unwrap().execute(v));
    match result {
        Ok(Ok(data)) => json!({"ok":true,"data":data}),
        Ok(Err(e)) => json!({"ok":false,"error":format!("{e:#}")}),
        Err(_) => json!({"ok":false,"error":"操作异常中止，请重新打开应用"}),
    }
}
unsafe extern "C" fn execute(p: *const c_char) -> *mut c_char {
    if p.is_null() {
        return std::ptr::null_mut();
    }
    let v = serde_json::from_slice(unsafe { CStr::from_ptr(p) }.to_bytes());
    let result = match v {
        Ok(v) => dispatch(v),
        Err(e) => json!({"ok":false,"error":e.to_string()}),
    };
    CString::new(result.to_string()).unwrap().into_raw()
}
unsafe extern "C" fn release(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) })
    }
}
fn main() -> anyhow::Result<()> {
    let root = std::env::var_os("RUSTCLICK_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var("HOME").unwrap())
                .join("Library/Application Support/RustClick")
        });
    ENGINE.set(Mutex::new(Engine::new(root))).ok();
    let args: Vec<_> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--request") {
        let request: Value = serde_json::from_str(
            args.get(2)
                .ok_or_else(|| anyhow::anyhow!("Missing JSON request"))?,
        )?;
        let v = dispatch(request);
        println!("{v}");
        if v["ok"] != true {
            std::process::exit(1)
        }
        return Ok(());
    }
    let exe = std::env::current_exe()?;
    let lib = exe
        .parent()
        .unwrap()
        .join("../Frameworks/libRustClickUI.dylib");
    let lib = CString::new(lib.to_str().unwrap())?;
    unsafe {
        let h = libc::dlopen(lib.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL);
        anyhow::ensure!(
            !h.is_null(),
            "请运行打包后的 RightClick.app：{}",
            CStr::from_ptr(libc::dlerror()).to_string_lossy()
        );
        let start = libc::dlsym(h, c"rustclick_start".as_ptr());
        let native = libc::dlsym(h, c"rustclick_native".as_ptr());
        anyhow::ensure!(
            !start.is_null() && !native.is_null(),
            "原生适配器未完整加载"
        );
        NATIVE
            .set(std::mem::transmute::<*mut libc::c_void, NativeFn>(native))
            .ok();
        let start: unsafe extern "C" fn(
            unsafe extern "C" fn(*const c_char) -> *mut c_char,
            unsafe extern "C" fn(*mut c_char),
        ) = std::mem::transmute(start);
        start(execute, release);
    }
    Ok(())
}
