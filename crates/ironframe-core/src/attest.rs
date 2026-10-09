//! Writing the environment attestation of a run: each dependency's endpoint, whether it answered,
//! and for a twin the stand-in it was, in the tool-neutral format of `ironframe-attestation`.
//! Ironframe writes it during `up` and on demand with `ironframe attest`, reusing the run `up`
//! started so both describe one run. ref:DEC-attestation-format

use crate::settings::{BindingKind, ResolvedEnvironment, split_endpoint};
use ironframe_attestation::{Attestation, DependencyRecord, Kind, Producer, Run};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};
use time::OffsetDateTime;

/// The run an environment is in: started by `up`, kept in its working directory so a later
/// `ironframe attest` records the same run. ref:DEC-attestation-format
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunRecord {
    /// The run's id.
    pub id: String,
    /// When `up` started it.
    #[serde(with = "time::serde::rfc3339")]
    pub started_at: OffsetDateTime,
}

impl RunRecord {
    /// A new run starting now, with a random id.
    pub fn start() -> Self {
        RunRecord { id: uuid::Uuid::new_v4().to_string(), started_at: OffsetDateTime::now_utc() }
    }
}

/// The attestation of `environment` in `run`, recorded now, with `reached` deciding for each
/// endpoint whether it answered. ref:DEC-attestation-format
pub fn attest(environment: &ResolvedEnvironment, run: &RunRecord, reached: &dyn Fn(&str) -> bool) -> Attestation {
    let recorded_at = OffsetDateTime::now_utc().max(run.started_at);
    let mut attestation =
        Attestation::new(&environment.environment, Run { id: run.id.clone(), started_at: run.started_at, recorded_at });
    attestation.producer = Some(Producer { name: "ironframe".into(), version: env!("CARGO_PKG_VERSION").into() });
    attestation.dependencies = environment
        .dependencies
        .iter()
        .map(|dependency| DependencyRecord {
            name: dependency.name.clone(),
            endpoint: dependency.endpoint.clone(),
            reached: reached(&dependency.endpoint),
            kind: match dependency.kind {
                BindingKind::Real => Kind::Real,
                BindingKind::Twin => Kind::StandIn,
            },
            stand_in: dependency.stand_in.clone(),
        })
        .collect();
    attestation
}

/// Whether the endpoint's host and port accept a TCP connection within `timeout` and keep it open.
/// A port forwarder, such as podman's on macOS, accepts a connection before anything listens behind
/// it and then closes it, so a connection closed or reset within a moment of opening counts as not
/// reached; a server that waits for the client to speak, or speaks first, counts as reached. An
/// endpoint without a port cannot be probed and counts as not reached. ref:DEC-attestation-format
pub fn tcp_reachable(endpoint: &str, timeout: Duration) -> bool {
    let (host, Some(port)) = split_endpoint(endpoint) else { return false };
    let Ok(addresses) = (host.as_str(), port).to_socket_addrs() else { return false };
    addresses.into_iter().any(|address| {
        let Ok(mut stream) = TcpStream::connect_timeout(&address, timeout) else { return false };
        if stream.set_read_timeout(Some(Duration::from_millis(300))).is_err() {
            return false;
        }
        let mut byte = [0u8; 1];
        match stream.read(&mut byte) {
            Ok(0) => false,
            Ok(_) => true,
            Err(error) => matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut),
        }
    })
}

/// Waits until the endpoint is reachable or `deadline` passes, trying every half second.
/// ref:DEC-attestation-format
pub fn wait_reachable(endpoint: &str, deadline: Duration) -> bool {
    let until = Instant::now() + deadline;
    loop {
        if tcp_reachable(endpoint, Duration::from_secs(1)) {
            return true;
        }
        if Instant::now() >= until {
            return false;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}
