//! A tiny application that knows nothing of Ironframe: it reads `PETSTORE_URL` the way many
//! applications do, from its environment or else a `.env` file in its working directory, adds a pet
//! to the Petstore API there and reads it back. Whether the API is the real service or a twin is
//! decided by the manifest beside it, not by the app. ref:REQ-example-reads-config

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

/// The setting the app reads.
const SETTING: &str = "PETSTORE_URL";

/// The base URL from the environment, else from `.env`, as a dotenv library would.
fn base_url() -> Option<String> {
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

/// The host, port and path prefix of an `http://` URL.
fn split_url(url: &str) -> Result<(String, u16, String), String> {
    let rest = url.strip_prefix("http://").ok_or_else(|| format!("{url} is not an http:// URL"))?;
    let (authority, path) = rest.split_once('/').map_or((rest, ""), |(a, p)| (a, p));
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, port.parse().map_err(|_| format!("bad port in {url}"))?),
        None => (authority, 80),
    };
    Ok((host.to_string(), port, format!("/{}", path.trim_end_matches('/')).trim_end_matches('/').to_string()))
}

/// One HTTP/1.1 exchange: the request line and body, and the status and body of the answer.
fn exchange(url: &str, method: &str, path: &str, body: Option<&str>) -> Result<(u16, String), String> {
    let (host, port, prefix) = split_url(url)?;
    let mut stream = TcpStream::connect((host.as_str(), port)).map_err(|e| format!("cannot connect: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).map_err(|e| e.to_string())?;
    let body = body.unwrap_or("");
    let request = format!(
        "{method} {prefix}{path} HTTP/1.1\r\nHost: {host}:{port}\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).map_err(|e| format!("cannot send: {e}"))?;
    let mut response = String::new();
    stream.read_to_string(&mut response).map_err(|e| format!("no response: {e}"))?;
    parse_response(&response)
}

/// The status and body of an HTTP/1.1 response read to its end.
fn parse_response(response: &str) -> Result<(u16, String), String> {
    let (head, body) = response.split_once("\r\n\r\n").ok_or("the response has no end of headers")?;
    let status = head.split_whitespace().nth(1).and_then(|s| s.parse().ok()).ok_or("the response has no status")?;
    Ok((status, body.to_string()))
}

/// The value of a top-level JSON field, as text: a number, or a string without its quotes.
fn field(json: &str, name: &str) -> Option<String> {
    let at = json.find(&format!("\"{name}\""))? + name.len() + 2;
    let rest = json[at..].trim_start().strip_prefix(':')?.trim_start();
    if let Some(quoted) = rest.strip_prefix('"') {
        return quoted.split('"').next().map(str::to_string);
    }
    Some(rest.chars().take_while(|c| c.is_ascii_digit()).collect())
}

fn run(url: &str) -> Result<String, String> {
    let (status, created) =
        exchange(url, "POST", "/pet", Some(r#"{"name":"Rex","photoUrls":[],"status":"available"}"#))?;
    if status != 200 {
        return Err(format!("adding a pet answered {status}: {created}"));
    }
    let id = field(&created, "id").filter(|id| !id.is_empty()).ok_or("the created pet has no id")?;
    let (status, read) = exchange(url, "GET", &format!("/pet/{id}"), None)?;
    if status != 200 {
        return Err(format!("reading pet {id} back answered {status}: {read}"));
    }
    match field(&read, "name").as_deref() {
        Some("Rex") => Ok(id),
        other => Err(format!("pet {id} read back with name {other:?}, not \"Rex\"")),
    }
}

fn main() -> std::process::ExitCode {
    let Some(url) = base_url() else {
        eprintln!("petstore-app: set {SETTING}, or write it to .env");
        return std::process::ExitCode::from(2);
    };
    match run(&url) {
        Ok(id) => {
            println!("petstore-app: {url} added pet {id} and read it back");
            std::process::ExitCode::SUCCESS
        }
        Err(reason) => {
            eprintln!("petstore-app: {url}: {reason}");
            std::process::ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ref:REQ-example-reads-config
    #[test]
    fn a_url_is_split_into_host_port_and_path() {
        assert_eq!(split_url("http://localhost:8080").unwrap(), ("localhost".into(), 8080, String::new()));
        assert_eq!(split_url("http://petstore/api/v3/").unwrap(), ("petstore".into(), 80, "/api/v3".into()));
        assert!(split_url("https://petstore.example.com").is_err());
    }

    /// ref:REQ-example-reads-config
    #[test]
    fn a_response_s_status_and_fields_are_read() {
        let (status, body) =
            parse_response("HTTP/1.1 200 OK\r\nContent-Length: 27\r\n\r\n{\"id\": 12, \"name\": \"Rex\"}").unwrap();
        assert_eq!(status, 200);
        assert_eq!(field(&body, "id").as_deref(), Some("12"));
        assert_eq!(field(&body, "name").as_deref(), Some("Rex"));
    }
}
