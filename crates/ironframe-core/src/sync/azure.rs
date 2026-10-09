//! Azure App Configuration: one key-value per setting, under the target's prefix and a label that
//! is the environment's name unless the target names one. A key already holding its value is not
//! written again. Azure's Rust SDK has no released App Configuration client, so the real calls use
//! the service's REST API, signed with HMAC-SHA256 from the store's connection string as the
//! service documents. ref:DEC-config-sync ref:azure-appconfig-rest ref:azure-appconfig-hmac

use super::{SyncError, SyncOutcome};
use crate::manifest::{AzureAppConfigurationTarget, SyncTarget};
use async_trait::async_trait;
use std::collections::BTreeMap;

/// The App Configuration calls the sync makes. ref:DEC-config-sync
#[async_trait]
pub trait AppConfigurationApi: Send + Sync {
    /// The value of `key` under `label`, if it is set.
    async fn get(&self, key: &str, label: &str) -> Result<Option<String>, String>;
    /// Sets `key` under `label` to `value`.
    async fn put(&self, key: &str, label: &str, value: &str) -> Result<(), String>;
}

/// Syncs settings into the target's store, writing only the keys whose value differs.
/// ref:DEC-config-sync
pub async fn sync(
    api: &dyn AppConfigurationApi,
    target: &AzureAppConfigurationTarget,
    environment: &str,
    settings: &BTreeMap<String, String>,
) -> Result<SyncOutcome, SyncError> {
    let fail = |reason: String| SyncError {
        target: super::describe(&SyncTarget::AzureAppConfiguration(target.clone()), environment),
        reason,
    };
    let label = target.label.as_deref().unwrap_or(environment);
    let mut written = Vec::new();
    for (key, value) in settings {
        let key = format!("{}{key}", target.prefix);
        if api.get(&key, label).await.map_err(fail)?.as_deref() == Some(value.as_str()) {
            continue;
        }
        api.put(&key, label, value).await.map_err(fail)?;
        written.push(key);
    }
    if written.is_empty() { Ok(SyncOutcome::Unchanged) } else { Ok(SyncOutcome::Updated(written.join(", "))) }
}

/// The parts of an App Configuration connection string, `Endpoint=...;Id=...;Secret=...`.
/// ref:azure-appconfig-hmac
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionString {
    /// The store's endpoint.
    pub endpoint: String,
    /// The access key's id.
    pub id: String,
    /// The access key's secret, base64 as Azure shows it.
    pub secret: String,
}

impl ConnectionString {
    /// Reads a connection string, or names the part it lacks.
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut parts = BTreeMap::new();
        for part in text.split(';').filter(|p| !p.trim().is_empty()) {
            let (key, value) =
                part.split_once('=').ok_or_else(|| format!("connection string part {part:?} has no ="))?;
            parts.insert(key.trim().to_ascii_lowercase(), value.trim().to_string());
        }
        let take = |key: &str| parts.get(key).cloned().ok_or_else(|| format!("connection string has no {key}"));
        Ok(ConnectionString { endpoint: take("endpoint")?, id: take("id")?, secret: take("secret")? })
    }
}

/// The headers that sign one App Configuration request: `x-ms-date`, `x-ms-content-sha256` and
/// `Authorization`. `path_and_query` is the request's path with its query, `host` its host, and
/// `date` an HTTP date. ref:azure-appconfig-hmac
#[cfg(feature = "azure")]
pub fn sign(
    method: &str,
    host: &str,
    path_and_query: &str,
    body: &[u8],
    date: &str,
    credential: &ConnectionString,
) -> Result<Vec<(String, String)>, String> {
    use base64::Engine;
    use hmac::{Hmac, Mac};
    use sha2::{Digest, Sha256};
    let engine = base64::engine::general_purpose::STANDARD;
    let content_hash = engine.encode(Sha256::digest(body));
    let to_sign = format!("{method}\n{path_and_query}\n{date};{host};{content_hash}");
    let key =
        engine.decode(&credential.secret).map_err(|e| format!("the connection string's secret is not base64: {e}"))?;
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).map_err(|e| e.to_string())?;
    mac.update(to_sign.as_bytes());
    let signature = engine.encode(mac.finalize().into_bytes());
    Ok(vec![
        ("x-ms-date".into(), date.into()),
        ("x-ms-content-sha256".into(), content_hash),
        (
            "Authorization".into(),
            format!(
                "HMAC-SHA256 Credential={}&SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature={signature}",
                credential.id
            ),
        ),
    ])
}

/// The REST API version the client speaks. ref:azure-appconfig-rest
#[cfg(feature = "azure")]
pub const API_VERSION: &str = "2023-11-01";

/// [`AppConfigurationApi`] over the REST API, signed with a connection string's access key.
/// ref:azure-appconfig-rest
#[cfg(feature = "azure")]
pub struct RestAppConfiguration {
    http: reqwest::Client,
    endpoint: reqwest::Url,
    credential: ConnectionString,
}

#[cfg(feature = "azure")]
impl RestAppConfiguration {
    /// A client for the store at `endpoint`, signing with `credential`.
    pub fn new(endpoint: &str, credential: ConnectionString) -> Result<Self, String> {
        let endpoint = reqwest::Url::parse(endpoint).map_err(|e| format!("endpoint {endpoint:?}: {e}"))?;
        Ok(RestAppConfiguration { http: reqwest::Client::new(), endpoint, credential })
    }

    fn url(&self, key: &str, label: &str) -> reqwest::Url {
        let mut url = self.endpoint.clone();
        url.path_segments_mut().expect("an https URL has path segments").clear().push("kv").push(key);
        url.query_pairs_mut().clear().append_pair("label", label).append_pair("api-version", API_VERSION);
        url
    }

    async fn send(
        &self,
        method: reqwest::Method,
        url: reqwest::Url,
        body: Vec<u8>,
    ) -> Result<reqwest::Response, String> {
        let date = time::OffsetDateTime::now_utc()
            .format(time::macros::format_description!(
                "[weekday repr:short], [day] [month repr:short] [year] [hour]:[minute]:[second] GMT"
            ))
            .map_err(|e| e.to_string())?;
        let host = url.host_str().unwrap_or_default().to_string();
        let host = match url.port() {
            Some(port) => format!("{host}:{port}"),
            None => host,
        };
        let path_and_query = match url.query() {
            Some(query) => format!("{}?{query}", url.path()),
            None => url.path().to_string(),
        };
        let mut request = self.http.request(method.clone(), url);
        for (name, value) in sign(method.as_str(), &host, &path_and_query, &body, &date, &self.credential)? {
            request = request.header(name, value);
        }
        if !body.is_empty() {
            request = request.header("Content-Type", "application/vnd.microsoft.appconfig.kv+json").body(body);
        }
        request.send().await.map_err(|e| e.to_string())
    }
}

#[cfg(feature = "azure")]
#[async_trait]
impl AppConfigurationApi for RestAppConfiguration {
    async fn get(&self, key: &str, label: &str) -> Result<Option<String>, String> {
        let response = self.send(reqwest::Method::GET, self.url(key, label), Vec::new()).await?;
        match response.status() {
            reqwest::StatusCode::NOT_FOUND => Ok(None),
            status if status.is_success() => {
                let body: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
                Ok(body.get("value").and_then(|v| v.as_str()).map(str::to_string))
            }
            status => Err(format!("GET {key}: HTTP {status}: {}", response.text().await.unwrap_or_default())),
        }
    }

    async fn put(&self, key: &str, label: &str, value: &str) -> Result<(), String> {
        let body = serde_json::to_vec(&serde_json::json!({ "value": value })).map_err(|e| e.to_string())?;
        let response = self.send(reqwest::Method::PUT, self.url(key, label), body).await?;
        if response.status().is_success() {
            Ok(())
        } else {
            let status = response.status();
            Err(format!("PUT {key}: HTTP {status}: {}", response.text().await.unwrap_or_default()))
        }
    }
}
