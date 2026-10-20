//! A twin's control plane, spoken over its admin API: Ironframe waits for a twin to answer, checks
//! its seed, forces the state and raises the faults the manifest gives, and reads the seed and the
//! history an attestation records. `ironframe twin` passes a person's commands through with the
//! meaning `lawtwin` gives them. Ironframe knows the API, never what a twin does behind it.
//! ref:DEC-twin-control-plane ref:DEC-history-digest

use crate::manifest::{Fault, Twin};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::{Duration, Instant};

/// Why a control-plane request failed. ref:DEC-twin-control-plane
#[derive(Debug, thiserror::Error)]
pub enum TwinError {
    /// Nothing answered at the control plane's URL.
    #[error("the control plane at {url} does not answer: {reason}")]
    Unreachable {
        /// The URL.
        url: String,
        /// Why.
        reason: String,
    },
    /// The twin refused a forced state, naming the law that forbids it.
    #[error("refused: the law `{law}` forbids this state: {reason}")]
    Refused {
        /// The law.
        law: String,
        /// Why.
        reason: String,
    },
    /// The twin answered with a failure.
    #[error("{0}")]
    Answered(String),
    /// A file the request needs could not be read.
    #[error("{0}")]
    Input(String),
}

impl TwinError {
    /// The exit status `lawtwin` gives the same failure: 2 for a refused state, 1 otherwise.
    pub fn exit_code(&self) -> u8 {
        match self {
            TwinError::Refused { .. } => 2,
            _ => 1,
        }
    }
}

/// An answer of the control plane: its status and body. ref:DEC-twin-control-plane
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    /// The HTTP status.
    pub status: u16,
    /// The body, as text.
    pub body: String,
}

impl Reply {
    /// The body when the status is a success, else the twin's `error`, as `lawtwin` reports it.
    pub fn ok(self) -> Result<String, TwinError> {
        if (200..300).contains(&self.status) {
            return Ok(self.body);
        }
        let value: Value = serde_json::from_str(&self.body).unwrap_or_default();
        Err(TwinError::Answered(
            value["error"]
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|| format!("the twin answered {}: {}", self.status, self.body)),
        ))
    }
}

/// The body as indented JSON when it is JSON, else as it is.
pub fn pretty(body: &str) -> String {
    serde_json::from_str::<Value>(body)
        .map(|v| serde_json::to_string_pretty(&v).unwrap_or_default())
        .unwrap_or_else(|_| body.to_string())
}

/// What the attestation records of a twin's run, read from its control plane, and the history it
/// was read from. ref:DEC-history-digest
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Observation {
    /// The twin's seed.
    pub seed: Option<u64>,
    /// `sha256:<hex>` of the history as JSON lines.
    pub history_digest: Option<String>,
    /// How many entries the history holds.
    pub history_entries: Option<u64>,
    /// The history as JSON lines, as the digest was taken over it.
    pub history: Option<String>,
}

/// What `up` learnt of a twin it started, kept in the environment's working directory so a later
/// `ironframe attest` and `ironframe twin` find it. ref:DEC-twin-control-plane
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TwinRecord {
    /// The control plane's URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admin: Option<String>,
    /// The seed the twin reported once set up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<u64>,
    /// The conformance level, when `up` read it from the image's label.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conformance: Option<String>,
    /// The faults raised at start, by name.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub faults: Vec<String>,
    /// Whether a state was forced at start.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub forced: bool,
}

/// The `sha256:<hex>` digest of a history. ref:DEC-history-digest
pub fn history_digest(history: &str) -> String {
    let digest = Sha256::digest(history.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("sha256:{hex}")
}

/// A twin's control plane at a URL. ref:DEC-twin-control-plane
#[derive(Debug, Clone)]
pub struct ControlPlane {
    /// The base URL, such as `http://127.0.0.1:9644`.
    pub url: String,
    client: reqwest::Client,
}

impl ControlPlane {
    /// The control plane at `url`.
    pub fn new(url: impl Into<String>) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("an HTTP client with a timeout builds");
        ControlPlane { url: url.into().trim_end_matches('/').to_string(), client }
    }

    /// Sends a request and returns the answer, whatever its status.
    pub async fn request(&self, method: &str, path: &str, body: Option<String>) -> Result<Reply, TwinError> {
        let method = reqwest::Method::from_bytes(method.as_bytes()).expect("the methods used are valid");
        let mut request = self.client.request(method, format!("{}{path}", self.url));
        if let Some(body) = body {
            request = request.header("content-type", "application/json").body(body);
        }
        let response = request
            .send()
            .await
            .map_err(|e| TwinError::Unreachable { url: self.url.clone(), reason: root_cause(&e) })?;
        let status = response.status().as_u16();
        let body = response
            .text()
            .await
            .map_err(|e| TwinError::Unreachable { url: self.url.clone(), reason: root_cause(&e) })?;
        Ok(Reply { status, body })
    }

    /// Whether `/healthz` answers 200.
    pub async fn healthy(&self) -> bool {
        matches!(self.request("GET", "/healthz", None).await, Ok(reply) if reply.status == 200)
    }

    /// Waits until `/healthz` answers or `deadline` passes, trying every quarter second.
    pub async fn wait_healthy(&self, deadline: Duration) -> bool {
        let until = Instant::now() + deadline;
        loop {
            if self.healthy().await {
                return true;
            }
            if Instant::now() >= until {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }

    /// `GET /v1/twin`: what the twin says it is.
    pub async fn describe(&self) -> Result<Value, TwinError> {
        let body = self.request("GET", "/v1/twin", None).await?.ok()?;
        serde_json::from_str(&body).map_err(|e| TwinError::Answered(format!("/v1/twin is not JSON: {e}")))
    }

    /// `GET /v1/state`, with every record when `records`.
    pub async fn inspect(&self, records: bool) -> Result<String, TwinError> {
        self.request("GET", if records { "/v1/state?records=true" } else { "/v1/state" }, None).await?.ok()
    }

    /// `POST /v1/state`: forces a state, or reports the law that refuses it.
    pub async fn force(&self, state: String) -> Result<String, TwinError> {
        let reply = self.request("POST", "/v1/state", Some(state)).await?;
        if reply.status == 422 {
            let value: Value = serde_json::from_str(&reply.body).unwrap_or_default();
            return Err(TwinError::Refused {
                law: value["law"].as_str().unwrap_or("?").to_string(),
                reason: value["reason"].as_str().unwrap_or("?").to_string(),
            });
        }
        reply.ok()
    }

    /// `POST /v1/faults/{name}`: raises a declared fault with its parameters.
    pub async fn raise(&self, fault: &Fault) -> Result<String, TwinError> {
        let params: serde_json::Map<String, Value> = fault.params.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        self.request("POST", &format!("/v1/faults/{}", fault.name), Some(Value::Object(params).to_string())).await?.ok()
    }

    /// `DELETE /v1/faults[/{name}]`: clears one fault, or every one.
    pub async fn clear(&self, name: Option<&str>) -> Result<String, TwinError> {
        let path = name.map_or_else(|| "/v1/faults".to_string(), |n| format!("/v1/faults/{n}"));
        self.request("DELETE", &path, None).await?.ok()
    }

    /// `GET /v1/faults`: the declared faults and the active ones.
    pub async fn faults(&self) -> Result<String, TwinError> {
        self.request("GET", "/v1/faults", None).await?.ok()
    }

    /// `POST /v1/clock/advance`: moves the twin clock forward by a duration such as `5s`.
    pub async fn advance(&self, by: &str) -> Result<String, TwinError> {
        self.request("POST", "/v1/clock/advance", Some(serde_json::json!({ "by": by }).to_string())).await?.ok()
    }

    /// `GET /v1/history`: as JSON lines, or as one JSON array when `array`.
    pub async fn history(&self, since: Option<u64>, limit: Option<u64>, array: bool) -> Result<String, TwinError> {
        let mut query = Vec::new();
        if let Some(since) = since {
            query.push(format!("since={since}"));
        }
        if let Some(limit) = limit {
            query.push(format!("limit={limit}"));
        }
        if !array {
            query.push("format=jsonl".into());
        }
        let path =
            if query.is_empty() { "/v1/history".to_string() } else { format!("/v1/history?{}", query.join("&")) };
        self.request("GET", &path, None).await?.ok()
    }

    /// `POST /v1/history/replay`: replays a history, JSON lines or a JSON array, through a fresh
    /// model, or the twin's own history when none is given, and reports the answers that differ and
    /// the laws that do not hold. ref:DEC-twin-control-plane
    pub async fn replay(&self, history: Option<String>) -> Result<String, TwinError> {
        self.request("POST", "/v1/history/replay", history).await?.ok()
    }

    /// `DELETE /v1/reset`: starts again from an empty state with the same seed.
    pub async fn reset(&self) -> Result<String, TwinError> {
        self.request("DELETE", "/v1/reset", None).await?.ok()
    }

    /// `POST /v1/seed`: starts again, empty, with a new seed.
    pub async fn set_seed(&self, seed: u64) -> Result<String, TwinError> {
        self.request("POST", "/v1/seed", Some(serde_json::json!({ "seed": seed }).to_string())).await?.ok()
    }

    /// The seed and the history's digest, read now. ref:DEC-history-digest
    pub async fn observe(&self) -> Result<Observation, TwinError> {
        let seed = self.describe().await?["seed"].as_u64();
        let history = self.history(None, None, false).await?;
        let entries = history.lines().filter(|l| !l.trim().is_empty()).count() as u64;
        Ok(Observation {
            seed,
            history_digest: Some(history_digest(&history)),
            history_entries: Some(entries),
            history: Some(history),
        })
    }

    /// Sets a twin up as its binding asks once it answers: the seed it was given is checked and
    /// set again when the twin reports another, then the state is forced and each fault raised, in
    /// order. A relative state path is read against `manifest_dir`. ref:DEC-twin-control-plane
    pub async fn set_up(&self, twin: &Twin, manifest_dir: &Path) -> Result<TwinRecord, TwinError> {
        let mut record = TwinRecord { admin: Some(self.url.clone()), ..TwinRecord::default() };
        let reported = self.describe().await?["seed"].as_u64();
        record.seed = reported;
        if let Some(seed) = twin.seed
            && reported != Some(seed)
        {
            self.set_seed(seed).await?;
            record.seed = Some(seed);
        }
        if let Some(state) = &twin.state {
            let text = match state {
                Value::String(path) => {
                    let path = manifest_dir.join(path);
                    std::fs::read_to_string(&path).map_err(|e| TwinError::Input(format!("{}: {e}", path.display())))?
                }
                other => other.to_string(),
            };
            self.force(text).await?;
            record.forced = true;
        }
        for fault in &twin.faults {
            self.raise(fault).await.map_err(|e| TwinError::Answered(format!("raising fault {:?}: {e}", fault.name)))?;
            record.faults.push(fault.name.clone());
        }
        Ok(record)
    }
}

fn root_cause(error: &reqwest::Error) -> String {
    let mut source: &dyn std::error::Error = error;
    while let Some(next) = source.source() {
        source = next;
    }
    source.to_string()
}

/// Parses `name=value` fault parameters as `lawtwin fault` does: a whole number is a number, and
/// anything else a string. ref:DEC-twin-control-plane
pub fn parse_fault(name: &str, params: &[String]) -> Result<Fault, TwinError> {
    let mut fault = Fault { name: name.to_string(), params: Default::default() };
    for param in params {
        let Some((key, value)) = param.split_once('=') else {
            return Err(TwinError::Input(format!("{param} is not a parameter; write name=value")));
        };
        let value = value.parse::<i64>().map(Value::from).unwrap_or_else(|_| value.into());
        fault.params.insert(key.to_string(), value);
    }
    Ok(fault)
}
