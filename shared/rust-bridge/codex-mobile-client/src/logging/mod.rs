use std::sync::OnceLock;

use tracing::Level;

static TRACING_SUBSCRIBER_INSTALLED: OnceLock<()> = OnceLock::new();

#[cfg(target_os = "android")]
mod android_logcat {
    use std::ffi::CString;
    use std::io::{self, Write};

    use tracing::{Level, Metadata};
    use tracing_subscriber::fmt::MakeWriter;

    const ANDROID_LOG_VERBOSE: i32 = 2;
    const ANDROID_LOG_DEBUG: i32 = 3;
    const ANDROID_LOG_INFO: i32 = 4;
    const ANDROID_LOG_WARN: i32 = 5;
    const ANDROID_LOG_ERROR: i32 = 6;
    const LOG_TAG: &str = "LitterRust";

    #[derive(Debug, Clone, Copy)]
    pub(crate) struct AndroidLogMakeWriter;

    pub(crate) struct AndroidLogWriter {
        priority: i32,
        buffer: Vec<u8>,
    }

    impl AndroidLogWriter {
        fn new(priority: i32) -> Self {
            Self {
                priority,
                buffer: Vec::new(),
            }
        }
    }

    impl Drop for AndroidLogWriter {
        fn drop(&mut self) {
            let _ = self.flush();
        }
    }

    impl Write for AndroidLogWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.buffer.extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            if self.buffer.is_empty() {
                return Ok(());
            }

            let rendered = String::from_utf8_lossy(&self.buffer);
            for line in rendered.lines() {
                write_android_log(self.priority, line);
            }
            self.buffer.clear();
            Ok(())
        }
    }

    impl<'a> MakeWriter<'a> for AndroidLogMakeWriter {
        type Writer = AndroidLogWriter;

        fn make_writer(&'a self) -> Self::Writer {
            AndroidLogWriter::new(ANDROID_LOG_INFO)
        }

        fn make_writer_for(&'a self, meta: &Metadata<'_>) -> Self::Writer {
            AndroidLogWriter::new(priority_for_level(meta.level()))
        }
    }

    fn priority_for_level(level: &Level) -> i32 {
        match *level {
            Level::TRACE => ANDROID_LOG_VERBOSE,
            Level::DEBUG => ANDROID_LOG_DEBUG,
            Level::INFO => ANDROID_LOG_INFO,
            Level::WARN => ANDROID_LOG_WARN,
            Level::ERROR => ANDROID_LOG_ERROR,
        }
    }

    fn write_android_log(priority: i32, line: &str) {
        let line = line.trim_end();
        if line.is_empty() {
            return;
        }

        let Ok(tag) = CString::new(LOG_TAG) else {
            return;
        };
        let message = line.replace('\0', "\\0");
        let Ok(message) = CString::new(message) else {
            return;
        };

        unsafe {
            __android_log_write(priority, tag.as_ptr(), message.as_ptr());
        }
    }

    #[link(name = "log")]
    unsafe extern "C" {
        fn __android_log_write(
            priority: i32,
            tag: *const std::ffi::c_char,
            text: *const std::ffi::c_char,
        ) -> i32;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevelName {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevelName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trace => "TRACE",
            Self::Debug => "DEBUG",
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
        }
    }

    fn into_tracing(self) -> Level {
        match self {
            Self::Trace => Level::TRACE,
            Self::Debug => Level::DEBUG,
            Self::Info => Level::INFO,
            Self::Warn => Level::WARN,
            Self::Error => Level::ERROR,
        }
    }
}

pub(crate) fn install_tracing_subscriber() {
    TRACING_SUBSCRIBER_INSTALLED.get_or_init(|| {
        // Default filter: keep our own crate logs verbose but silence chatty
        // transport-layer crates. quinn / quinn_proto at TRACE under heavy
        // QUIC load (e.g., an iroh stream carrying a multi-MB
        // thread/list response) emits multiple log lines per packet, which
        // on iOS jetsamed the app inside seconds. RUST_LOG overrides if set.
        const DEFAULT_FILTER: &str = "info,\
            codex_mobile_client=trace,\
            mobile=trace,\
            store=debug,\
            quinn=warn,\
            quinn_proto=warn,\
            quinn_udp=warn,\
            rustls=warn,\
            ring=warn,\
            h2=warn,\
            hyper=warn,\
            tokio_tungstenite=warn,\
            tungstenite=warn";

        let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(DEFAULT_FILTER));

        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .without_time()
            .compact()
            .with_target(true)
            .with_env_filter(env_filter);
        #[cfg(target_os = "android")]
        let subscriber = subscriber
            .with_writer(android_logcat::AndroidLogMakeWriter)
            .finish();
        #[cfg(target_os = "ios")]
        let subscriber = subscriber.with_writer(std::io::stderr).finish();
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let subscriber = subscriber.finish();
        if tracing::subscriber::set_global_default(subscriber).is_ok() {
            tracing::info!(target: "mobile", "Rust tracing subscriber installed");
        }
    });
}

pub(crate) fn log_rust(
    level: LogLevelName,
    subsystem: impl Into<String>,
    category: impl Into<String>,
    message: impl Into<String>,
    fields_json: Option<String>,
) {
    install_tracing_subscriber();

    let subsystem = subsystem.into();
    let category = category.into();
    let message = message.into();
    let fields_json = fields_json.filter(|value| !value.trim().is_empty());

    match (level.into_tracing(), fields_json.as_deref()) {
        (Level::TRACE, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::TRACE,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::DEBUG, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::DEBUG,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::INFO, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::INFO,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::WARN, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::WARN,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::ERROR, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::ERROR,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::TRACE, None) => {
            tracing::event!(target: "mobile", Level::TRACE, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::DEBUG, None) => {
            tracing::event!(target: "mobile", Level::DEBUG, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::INFO, None) => {
            tracing::event!(target: "mobile", Level::INFO, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::WARN, None) => {
            tracing::event!(target: "mobile", Level::WARN, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::ERROR, None) => {
            tracing::event!(target: "mobile", Level::ERROR, subsystem = %subsystem, category = %category, "{message}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::LogLevelName;

    #[test]
    fn log_level_name_strings_match_expected_format() {
        assert_eq!(LogLevelName::Trace.as_str(), "TRACE");
        assert_eq!(LogLevelName::Debug.as_str(), "DEBUG");
        assert_eq!(LogLevelName::Info.as_str(), "INFO");
        assert_eq!(LogLevelName::Warn.as_str(), "WARN");
        assert_eq!(LogLevelName::Error.as_str(), "ERROR");
    }
}
