//! The configuration service: an HTTP server that serves each environment's connection settings,
//! the same settings Ironframe writes to env files and syncs into the clouds, so an application
//! that fetches its configuration over HTTP reads exactly what the others read. It serves a
//! settings document, re-read on every request so a new `ironframe up` is visible at once, and it
//! never writes. ref:DEC-config-service

use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use ironframe_core::settings::{SettingsDocument, render_dotenv};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

/// Where the service's settings come from: a file, read on each request, or a fixed document.
/// ref:DEC-config-service
#[derive(Debug, Clone)]
pub enum Source {
    /// A settings document on disk, as `ironframe up` writes it.
    File(PathBuf),
    /// A document held in memory.
    Fixed(SettingsDocument),
}

impl Source {
    fn load(&self) -> Result<SettingsDocument, String> {
        match self {
            Source::Fixed(document) => Ok(document.clone()),
            Source::File(path) => {
                let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
                serde_json::from_str(&text).map_err(|e| format!("{} is not a settings document: {e}", path.display()))
            }
        }
    }
}

fn error(status: StatusCode, message: impl Into<String>) -> Response {
    (status, Json(serde_json::json!({ "error": message.into() }))).into_response()
}

type Shared = Arc<Source>;

fn environment(source: &Source, name: &str) -> Result<BTreeMap<String, String>, Box<Response>> {
    let document = source.load().map_err(|e| Box::new(error(StatusCode::SERVICE_UNAVAILABLE, e)))?;
    document.environments.get(name).cloned().ok_or_else(|| {
        Box::new(error(
            StatusCode::NOT_FOUND,
            format!(
                "no environment {name:?}; this service has {}",
                document.environments.keys().cloned().collect::<Vec<_>>().join(", ")
            ),
        ))
    })
}

async fn health() -> &'static str {
    "ok\n"
}

async fn environments(State(source): State<Shared>) -> Response {
    match source.load() {
        Ok(document) => Json(serde_json::json!({
            "project": document.project,
            "environments": document.environments.keys().collect::<Vec<_>>(),
        }))
        .into_response(),
        Err(e) => error(StatusCode::SERVICE_UNAVAILABLE, e),
    }
}

async fn settings_json(State(source): State<Shared>, Path(name): Path<String>) -> Response {
    match environment(&source, &name) {
        Ok(settings) => Json(settings).into_response(),
        Err(response) => *response,
    }
}

async fn settings_env(State(source): State<Shared>, Path(name): Path<String>) -> Response {
    match environment(&source, &name) {
        Ok(settings) => (
            [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
            render_dotenv(&format!("Settings of environment {name}"), &settings),
        )
            .into_response(),
        Err(response) => *response,
    }
}

async fn setting(State(source): State<Shared>, Path((name, key)): Path<(String, String)>) -> Response {
    match environment(&source, &name) {
        Ok(settings) => match settings.get(&key) {
            Some(value) => ([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], value.clone()).into_response(),
            None => error(StatusCode::NOT_FOUND, format!("environment {name:?} has no setting {key}")),
        },
        Err(response) => *response,
    }
}

/// The service's routes: `/healthz`, `/v1/environments`, `/v1/environments/{env}` as JSON,
/// `/v1/environments/{env}/env` as dotenv, and `/v1/environments/{env}/settings/{key}` as the bare
/// value. ref:DEC-config-service
pub fn router(source: Source) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/environments", get(environments))
        .route("/v1/environments/{name}", get(settings_json))
        .route("/v1/environments/{name}/env", get(settings_env))
        .route("/v1/environments/{name}/settings/{key}", get(setting))
        .with_state(Arc::new(source))
}
