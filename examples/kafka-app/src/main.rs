//! A tiny application that knows nothing of Ironframe: it reads `KAFKA_BOOTSTRAP_SERVERS` the way
//! many applications do, from its environment or else a `.env` file in its working directory, and
//! asks each broker for its supported API versions over the Kafka wire protocol. Whether the
//! broker is the real Kafka or a twin is decided by the manifest beside it, not by the app.
//! ref:REQ-example-reads-config

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

/// The setting the app reads.
const SETTING: &str = "KAFKA_BOOTSTRAP_SERVERS";

/// The bootstrap servers from the environment, else from `.env`, as a dotenv library would.
fn bootstrap_servers() -> Option<String> {
    if let Ok(value) = std::env::var(SETTING) {
        return Some(value);
    }
    let text = std::fs::read_to_string(".env").ok()?;
    text.lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .filter_map(|line| line.split_once('='))
        .find(|(key, _)| key.trim() == SETTING)
        .map(|(_, value)| value.trim().trim_matches('"').to_string())
}

/// An ApiVersions request, version 0, framed with its length.
fn api_versions_request(correlation: i32) -> Vec<u8> {
    let client = b"kafka-app";
    let mut body = Vec::new();
    body.extend_from_slice(&18i16.to_be_bytes());
    body.extend_from_slice(&0i16.to_be_bytes());
    body.extend_from_slice(&correlation.to_be_bytes());
    body.extend_from_slice(&(client.len() as i16).to_be_bytes());
    body.extend_from_slice(client);
    let mut framed = (body.len() as i32).to_be_bytes().to_vec();
    framed.extend(body);
    framed
}

/// Asks one broker for its API versions and returns how many APIs it supports.
fn probe(server: &str) -> Result<usize, String> {
    let mut stream = TcpStream::connect(server).map_err(|e| format!("cannot connect: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).map_err(|e| e.to_string())?;
    stream.write_all(&api_versions_request(1)).map_err(|e| format!("cannot send: {e}"))?;
    let mut size = [0u8; 4];
    stream.read_exact(&mut size).map_err(|e| format!("no response: {e}"))?;
    let mut response = vec![0u8; i32::from_be_bytes(size).max(0) as usize];
    stream.read_exact(&mut response).map_err(|e| format!("short response: {e}"))?;
    if response.len() < 10 {
        return Err("response too short".into());
    }
    let correlation = i32::from_be_bytes(response[0..4].try_into().unwrap());
    let error = i16::from_be_bytes(response[4..6].try_into().unwrap());
    let count = i32::from_be_bytes(response[6..10].try_into().unwrap());
    if correlation != 1 {
        return Err(format!("response for request {correlation}, expected 1"));
    }
    if error != 0 {
        return Err(format!("broker answered with error code {error}"));
    }
    Ok(count.max(0) as usize)
}

fn main() -> std::process::ExitCode {
    let Some(servers) = bootstrap_servers() else {
        eprintln!("kafka-app: set {SETTING}, or write it to .env");
        return std::process::ExitCode::from(2);
    };
    let mut failed = false;
    for server in servers.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        match probe(server) {
            Ok(count) => println!("kafka-app: {server} supports {count} APIs"),
            Err(reason) => {
                eprintln!("kafka-app: {server}: {reason}");
                failed = true;
            }
        }
    }
    if failed { std::process::ExitCode::from(1) } else { std::process::ExitCode::SUCCESS }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ref:REQ-example-reads-config
    #[test]
    fn the_api_versions_request_is_framed_with_its_length_and_names_the_client() {
        let request = api_versions_request(7);
        assert_eq!(i32::from_be_bytes(request[0..4].try_into().unwrap()) as usize, request.len() - 4);
        assert_eq!(&request[4..6], &18i16.to_be_bytes());
        assert_eq!(&request[8..12], &7i32.to_be_bytes());
        assert!(request.ends_with(b"kafka-app"));
    }
}
