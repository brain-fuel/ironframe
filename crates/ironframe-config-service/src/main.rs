//! The configuration service's entry point: `IRONFRAME_SETTINGS` names the settings document and
//! `IRONFRAME_LISTEN` the address, `0.0.0.0:8700` unless set. ref:DEC-config-service

use ironframe_config_service::{Source, router};

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let settings = std::env::var("IRONFRAME_SETTINGS").unwrap_or_else(|_| "/etc/ironframe/settings.json".into());
    let listen = std::env::var("IRONFRAME_LISTEN").unwrap_or_else(|_| "0.0.0.0:8700".into());
    let listener = match tokio::net::TcpListener::bind(&listen).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("ironframe-config-service: cannot listen on {listen}: {error}");
            return std::process::ExitCode::from(2);
        }
    };
    eprintln!("ironframe-config-service: serving {settings} on {listen}");
    let shutdown = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    match axum::serve(listener, router(Source::File(settings.into()))).with_graceful_shutdown(shutdown).await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("ironframe-config-service: {error}");
            std::process::ExitCode::from(1)
        }
    }
}
