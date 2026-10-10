//! A tiny application that knows nothing of Ironframe: it reads `KAFKA_BOOTSTRAP_SERVERS` the way
//! many applications do, from its environment or else a `.env` file in its working directory, and
//! asks each broker over the Kafka wire protocol for its supported API versions and for the
//! metadata of the app's topic, which a broker that creates topics on first use creates. Whether the
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

/// A Metadata request, version 0, for one topic, framed with its length. A broker that creates
/// topics on first use creates it.
fn metadata_request(correlation: i32, topic: &str) -> Vec<u8> {
    let client = b"kafka-app";
    let mut body = Vec::new();
    body.extend_from_slice(&3i16.to_be_bytes());
    body.extend_from_slice(&0i16.to_be_bytes());
    body.extend_from_slice(&correlation.to_be_bytes());
    body.extend_from_slice(&(client.len() as i16).to_be_bytes());
    body.extend_from_slice(client);
    body.extend_from_slice(&1i32.to_be_bytes());
    body.extend_from_slice(&(topic.len() as i16).to_be_bytes());
    body.extend_from_slice(topic.as_bytes());
    let mut framed = (body.len() as i32).to_be_bytes().to_vec();
    framed.extend(body);
    framed
}

/// Sends a framed request and reads the framed response.
fn round_trip(stream: &mut TcpStream, request: &[u8]) -> Result<Vec<u8>, String> {
    stream.write_all(request).map_err(|e| format!("cannot send: {e}"))?;
    let mut size = [0u8; 4];
    stream.read_exact(&mut size).map_err(|e| format!("no response: {e}"))?;
    let mut response = vec![0u8; i32::from_be_bytes(size).max(0) as usize];
    stream.read_exact(&mut response).map_err(|e| format!("short response: {e}"))?;
    Ok(response)
}

/// A reader over a response's fields, failing on a short response.
struct Fields<'a>(&'a [u8]);

impl Fields<'_> {
    fn take(&mut self, n: usize) -> Result<&[u8], String> {
        if self.0.len() < n {
            return Err("response too short".into());
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Ok(head)
    }
    fn int16(&mut self) -> Result<i16, String> {
        Ok(i16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn int32(&mut self) -> Result<i32, String> {
        Ok(i32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn string(&mut self) -> Result<String, String> {
        let length = self.int16()?.max(0) as usize;
        Ok(String::from_utf8_lossy(self.take(length)?).into_owned())
    }
}

/// Reads a Metadata version 0 response: the number of brokers, and the topic's error code and
/// number of partitions.
fn read_metadata(response: &[u8]) -> Result<(usize, i16, usize), String> {
    let mut fields = Fields(response);
    if fields.int32()? != 2 {
        return Err("metadata answered another request".into());
    }
    let brokers = fields.int32()?.max(0) as usize;
    for _ in 0..brokers {
        fields.int32()?;
        fields.string()?;
        fields.int32()?;
    }
    if fields.int32()? < 1 {
        return Err("metadata named no topic".into());
    }
    let error = fields.int16()?;
    fields.string()?;
    let partitions = fields.int32()?.max(0) as usize;
    Ok((brokers, error, partitions))
}

/// The topic the app asks the broker about.
const TOPIC: &str = "kafka-app";

/// Asks one broker for its API versions and for the app's topic, and returns how many APIs it
/// supports and how many partitions the topic has.
fn probe(server: &str) -> Result<(usize, usize), String> {
    let mut stream = TcpStream::connect(server).map_err(|e| format!("cannot connect: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).map_err(|e| e.to_string())?;
    let response = round_trip(&mut stream, &api_versions_request(1))?;
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
    let (_, error, partitions) = read_metadata(&round_trip(&mut stream, &metadata_request(2, TOPIC))?)?;
    if error != 0 {
        return Err(format!("metadata for topic {TOPIC} answered with error code {error}"));
    }
    Ok((count.max(0) as usize, partitions))
}

fn main() -> std::process::ExitCode {
    let Some(servers) = bootstrap_servers() else {
        eprintln!("kafka-app: set {SETTING}, or write it to .env");
        return std::process::ExitCode::from(2);
    };
    let mut failed = false;
    for server in servers.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        match probe(server) {
            Ok((count, partitions)) => {
                println!("kafka-app: {server} supports {count} APIs; topic {TOPIC} has {partitions} partition(s)")
            }
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

    /// ref:REQ-example-reads-config
    #[test]
    fn a_metadata_response_gives_the_brokers_and_the_topic_s_partitions() {
        let request = metadata_request(2, "orders");
        assert_eq!(&request[4..6], &3i16.to_be_bytes());
        assert!(request.ends_with(b"orders"));
        let mut response = Vec::new();
        response.extend_from_slice(&2i32.to_be_bytes());
        response.extend_from_slice(&1i32.to_be_bytes());
        response.extend_from_slice(&0i32.to_be_bytes());
        response.extend_from_slice(&9i16.to_be_bytes());
        response.extend_from_slice(b"localhost");
        response.extend_from_slice(&9092i32.to_be_bytes());
        response.extend_from_slice(&1i32.to_be_bytes());
        response.extend_from_slice(&0i16.to_be_bytes());
        response.extend_from_slice(&6i16.to_be_bytes());
        response.extend_from_slice(b"orders");
        response.extend_from_slice(&3i32.to_be_bytes());
        assert_eq!(read_metadata(&response).unwrap(), (1, 0, 3));
        assert!(read_metadata(&response[..6]).is_err());
    }
}
