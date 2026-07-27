use jni::JNIEnv;
use jni::objects::{GlobalRef, JClass, JObject, JString};
use jni::sys::jstring;
use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

static ANDROID_CONTEXT_REF: OnceLock<GlobalRef> = OnceLock::new();
static ANDROID_CONTEXT_INITIALIZED: AtomicBool = AtomicBool::new(false);

/// Bundled CA bundle used to seed `SSL_CERT_FILE` on mobile platforms where
/// the OS certificate store is not consulted by rustls native roots. Same
/// bundle as the iOS in-process path in `session::connection`.
#[cfg(any(target_os = "ios", target_os = "android"))]
static BUNDLED_CACERT_PEM: &[u8] = include_bytes!("../cacert.pem");

/// Write the bundled CA bundle to `CODEX_HOME/cacert.pem` (if missing) and
/// point `SSL_CERT_FILE` at it. Idempotent: an existing writable bundle is
/// reused, and an already-set `SSL_CERT_FILE` that resolves to a file is
/// preserved. Called once from the Android JNI bootstrap (`nativeBridgeInit`)
/// before any network code runs.
#[cfg(any(target_os = "ios", target_os = "android"))]
pub(crate) fn init_tls_roots() {
    if let Some(existing) = std::env::var_os("SSL_CERT_FILE") {
        if PathBuf::from(&existing).is_file() {
            return;
        }
    }

    let codex_home = match std::env::var("CODEX_HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => return,
    };
    let pem_path = codex_home.join("cacert.pem");
    if !pem_path.exists() {
        if let Err(e) = std::fs::write(&pem_path, BUNDLED_CACERT_PEM) {
            tracing::warn!("failed to write cacert.pem: {e}");
            return;
        }
    }
    unsafe {
        std::env::set_var("SSL_CERT_FILE", &pem_path);
    }
}

/// Early Android bootstrap invoked from `UniffiInit.ensure()` before any
/// UniFFI class is instantiated. Sets `HOME`, `CODEX_HOME`, and `TMPDIR` —
/// process env vars that Java cannot set directly — and seeds local TLS
/// roots. Replaces the former `codex-bridge` JNI shim; the symbol name is
/// unchanged so `UniffiInit.kt` resolves it from `libcodex_mobile_client.so`.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_litter_android_core_bridge_UniffiInit_nativeBridgeInit(
    mut env: JNIEnv,
    _class: JClass,
    home_dir: JString,
    codex_home_dir: JString,
) {
    let home: String = match env.get_string(&home_dir) {
        Ok(s) => s.into(),
        Err(_) => return,
    };
    let codex_home: String = match env.get_string(&codex_home_dir) {
        Ok(s) => s.into(),
        Err(_) => return,
    };

    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("CODEX_HOME", &codex_home);
        if std::env::var("TMPDIR").is_err() {
            let tmpdir = format!("{home}/tmp");
            let _ = std::fs::create_dir_all(&tmpdir);
            std::env::set_var("TMPDIR", &tmpdir);
        }
    }
    init_tls_roots();
    tracing::info!(
        "[codex-mobile-client] Android init: HOME={}, CODEX_HOME={}",
        home,
        codex_home
    );
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_litter_android_core_bridge_UniffiInit_nativeMobileClientInit(
    env: JNIEnv,
    _class: JClass,
    context: JObject,
) {
    if ANDROID_CONTEXT_INITIALIZED.load(Ordering::Acquire) {
        return;
    }

    let java_vm = env
        .get_java_vm()
        .expect("failed to get JavaVM for codex mobile client Android init");
    let context_ref = env
        .new_global_ref(context)
        .expect("failed to retain Android context for codex mobile client");

    let java_vm_ptr = java_vm.get_java_vm_pointer().cast::<c_void>();
    let context_ptr = context_ref.as_obj().as_raw().cast::<c_void>();

    let _ = ANDROID_CONTEXT_REF.set(context_ref);

    if !ANDROID_CONTEXT_INITIALIZED.swap(true, Ordering::AcqRel) {
        unsafe {
            ndk_context::initialize_android_context(java_vm_ptr, context_ptr);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_litter_android_core_bridge_UniffiInit_nativeMobileClientContextProbe(
    env: JNIEnv,
    _class: JClass,
) -> jstring {
    let message = match std::panic::catch_unwind(|| {
        let context = ndk_context::android_context();
        let _ = context.vm();
        let _ = context.context();

        let _resolver = iroh::dns::DnsResolver::new();

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("building tokio runtime: {error}"))?;
        runtime
            .block_on(async {
                let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
                    .bind()
                    .await
                    .map_err(|error| format!("binding iroh endpoint: {error}"))?;
                endpoint.close().await;
                Ok::<(), String>(())
            })
            .map_err(|error| format!("probing iroh endpoint: {error}"))?;

        Ok::<String, String>("ok".to_string())
    }) {
        Ok(Ok(message)) => message,
        Ok(Err(message)) => format!("error: {message}"),
        Err(payload) => {
            let message = payload
                .downcast_ref::<&str>()
                .map(|value| (*value).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".to_string());
            format!("panic: {message}")
        }
    };

    env.new_string(message)
        .unwrap_or_else(|_| JString::from(JObject::null()))
        .into_raw()
}
