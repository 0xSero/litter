use jni::JNIEnv;
use jni::objects::{GlobalRef, JClass, JObject, JString};
use jni::sys::jstring;
use std::ffi::c_void;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

static ANDROID_CONTEXT_REF: OnceLock<GlobalRef> = OnceLock::new();
static ANDROID_CONTEXT_INITIALIZED: AtomicBool = AtomicBool::new(false);

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
