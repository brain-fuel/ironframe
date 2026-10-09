//! What the tests share: manifests, a recording command runner, and recording cloud clients.
//! ref:DEC-config-sync

#![allow(dead_code)]

use async_trait::async_trait;
use ironframe_core::manifest::Manifest;
use ironframe_core::ops::Clouds;
use ironframe_core::process::{CommandOutput, CommandRunner};
use ironframe_core::sync::aws::AppConfigApi;
use ironframe_core::sync::azure::AppConfigurationApi;
use ironframe_core::sync::gcp::{ParameterManagerApi, VersionCreated};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// A small manifest with a podman environment, a hosted real dependency and an AWS environment.
pub const MANIFEST: &str = r#"
version: 1
project: shop
dependencies:
  kafka:
    settings:
      KAFKA_BOOTSTRAP_SERVERS: ${endpoint}
      KAFKA_KIND: ${kind}
  payments:
    settings:
      PAYMENTS_URL: ${endpoint}
      PAYMENTS_HOST: ${host}
      PAYMENTS_PORT: ${port}
      PAYMENTS_CREDENTIALS: ${credentials}
environments:
  local:
    runtime: podman
    dependencies:
      kafka:
        twin:
          image: lawtwin/kafka
          version: 0.1.0
          conformance: unrated
          ports: [9092, 9644]
          config: {seed: 42}
          env: {LOG_LEVEL: debug}
      payments:
        twin:
          image: ghcr.io/example/payments-twin
          version: 2.0.0
          conformance: L1
          ports: [8080]
          endpoint: http://localhost:8080/v1
          credentials: env:PAYMENTS_TOKEN
    sync:
      - env_file: {path: .env.local}
  staging:
    runtime: aws
    cloud:
      modules: ../modules
      region: eu-west-1
      vpc_id: vpc-1
      subnet_ids: [subnet-1, subnet-2]
      cpu: 512
    dependencies:
      kafka:
        twin:
          image: lawtwin/kafka
          version: 0.1.0
          conformance: unrated
          ports: [9092]
      payments:
        real:
          endpoint: https://payments.example.com
          credentials: aws-secretsmanager:shop/payments
    sync:
      - aws_appconfig: {region: eu-west-1, application: shop, profile: connections}
"#;

/// The shared manifest, parsed.
pub fn manifest() -> Manifest {
    Manifest::parse(MANIFEST).expect("the test manifest is valid")
}

/// The example application's manifest.
pub fn example_manifest_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../examples/kafka-app/ironframe.yaml")
}

/// How a recorder answers a command, from its arguments.
type Answer = Arc<dyn Fn(&[String]) -> CommandOutput + Send + Sync>;

/// A command runner that records every call and answers from a function of the arguments.
#[derive(Clone)]
pub struct Recorder {
    pub calls: Arc<Mutex<Vec<Vec<String>>>>,
    answer: Answer,
}

impl Recorder {
    pub fn new(answer: impl Fn(&[String]) -> CommandOutput + Send + Sync + 'static) -> Self {
        Recorder { calls: Arc::default(), answer: Arc::new(answer) }
    }

    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().iter().map(|c| c.join(" ")).collect()
    }
}

impl CommandRunner for Recorder {
    fn run(&self, _program: &Path, args: &[String], _stream: bool) -> std::io::Result<CommandOutput> {
        self.calls.lock().unwrap().push(args.to_vec());
        Ok((self.answer)(args))
    }
}

pub fn ok(stdout: &str) -> CommandOutput {
    CommandOutput { success: true, stdout: stdout.into(), stderr: String::new() }
}

pub fn failed(stderr: &str) -> CommandOutput {
    CommandOutput { success: false, stdout: String::new(), stderr: stderr.into() }
}

/// Points Ironframe at fake podman and OpenTofu binaries; the recorder answers for them.
pub fn fake_tools() {
    // SAFETY: every test sets the same values, so concurrent writes cannot disagree.
    unsafe {
        std::env::set_var("IRONFRAME_PODMAN", "/fake/podman");
        std::env::set_var("IRONFRAME_TOFU", "/fake/tofu");
    }
}

/// An in-memory AppConfig that records calls.
#[derive(Default)]
pub struct FakeAppConfig {
    pub calls: Mutex<Vec<String>>,
    pub applications: Mutex<BTreeMap<String, String>>,
    pub environments: Mutex<BTreeMap<String, String>>,
    pub profiles: Mutex<BTreeMap<String, String>>,
    pub versions: Mutex<Vec<Vec<u8>>>,
}

impl FakeAppConfig {
    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
    fn record(&self, call: String) {
        self.calls.lock().unwrap().push(call);
    }
}

#[async_trait]
impl AppConfigApi for FakeAppConfig {
    async fn find_application(&self, name: &str) -> Result<Option<String>, String> {
        Ok(self.applications.lock().unwrap().get(name).cloned())
    }
    async fn create_application(&self, name: &str) -> Result<String, String> {
        self.record(format!("create_application {name}"));
        self.applications.lock().unwrap().insert(name.into(), format!("app-{name}"));
        Ok(format!("app-{name}"))
    }
    async fn find_environment(&self, application: &str, name: &str) -> Result<Option<String>, String> {
        Ok(self.environments.lock().unwrap().get(&format!("{application}/{name}")).cloned())
    }
    async fn create_environment(&self, application: &str, name: &str) -> Result<String, String> {
        self.record(format!("create_environment {application} {name}"));
        self.environments.lock().unwrap().insert(format!("{application}/{name}"), format!("env-{name}"));
        Ok(format!("env-{name}"))
    }
    async fn find_profile(&self, application: &str, name: &str) -> Result<Option<String>, String> {
        Ok(self.profiles.lock().unwrap().get(&format!("{application}/{name}")).cloned())
    }
    async fn create_profile(&self, application: &str, name: &str) -> Result<String, String> {
        self.record(format!("create_profile {application} {name}"));
        self.profiles.lock().unwrap().insert(format!("{application}/{name}"), format!("profile-{name}"));
        Ok(format!("profile-{name}"))
    }
    async fn latest_version(&self, _application: &str, _profile: &str) -> Result<Option<(i32, Vec<u8>)>, String> {
        let versions = self.versions.lock().unwrap();
        Ok(versions.last().map(|v| (versions.len() as i32, v.clone())))
    }
    async fn create_version(&self, application: &str, profile: &str, content: Vec<u8>) -> Result<i32, String> {
        self.record(format!("create_version {application} {profile}"));
        let mut versions = self.versions.lock().unwrap();
        versions.push(content);
        Ok(versions.len() as i32)
    }
    async fn deploy(
        &self,
        application: &str,
        environment: &str,
        profile: &str,
        version: i32,
        strategy: &str,
    ) -> Result<i32, String> {
        self.record(format!("deploy {application} {environment} {profile} {version} {strategy}"));
        Ok(1)
    }
}

/// An in-memory Parameter Manager that records calls.
#[derive(Default)]
pub struct FakeParameterManager {
    pub calls: Mutex<Vec<String>>,
    pub parameters: Mutex<BTreeMap<String, BTreeMap<String, Vec<u8>>>>,
}

#[async_trait]
impl ParameterManagerApi for FakeParameterManager {
    async fn parameter_exists(&self, name: &str) -> Result<bool, String> {
        Ok(self.parameters.lock().unwrap().contains_key(name))
    }
    async fn create_parameter(&self, parent: &str, id: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("create_parameter {parent} {id}"));
        self.parameters.lock().unwrap().insert(format!("{parent}/parameters/{id}"), BTreeMap::new());
        Ok(())
    }
    async fn create_version(&self, parameter: &str, id: &str, data: Vec<u8>) -> Result<VersionCreated, String> {
        self.calls.lock().unwrap().push(format!("create_version {parameter} {id}"));
        let mut parameters = self.parameters.lock().unwrap();
        let versions = parameters.get_mut(parameter).ok_or("no such parameter")?;
        if versions.contains_key(id) {
            return Ok(VersionCreated::AlreadyExists);
        }
        versions.insert(id.into(), data);
        Ok(VersionCreated::Created)
    }
}

/// An in-memory App Configuration store that records writes.
#[derive(Default)]
pub struct FakeAppConfiguration {
    pub puts: Mutex<Vec<String>>,
    pub values: Mutex<BTreeMap<(String, String), String>>,
}

#[async_trait]
impl AppConfigurationApi for FakeAppConfiguration {
    async fn get(&self, key: &str, label: &str) -> Result<Option<String>, String> {
        Ok(self.values.lock().unwrap().get(&(key.to_string(), label.to_string())).cloned())
    }
    async fn put(&self, key: &str, label: &str, value: &str) -> Result<(), String> {
        self.puts.lock().unwrap().push(format!("{key}@{label}={value}"));
        self.values.lock().unwrap().insert((key.into(), label.into()), value.into());
        Ok(())
    }
}

/// Cloud clients that hand out shared fakes.
#[derive(Default, Clone)]
pub struct FakeClouds {
    pub aws: Arc<FakeAppConfig>,
    pub gcp: Arc<FakeParameterManager>,
    pub azure: Arc<FakeAppConfiguration>,
}

struct Shared<T>(Arc<T>);

#[async_trait]
impl AppConfigApi for Shared<FakeAppConfig> {
    async fn find_application(&self, n: &str) -> Result<Option<String>, String> {
        self.0.find_application(n).await
    }
    async fn create_application(&self, n: &str) -> Result<String, String> {
        self.0.create_application(n).await
    }
    async fn find_environment(&self, a: &str, n: &str) -> Result<Option<String>, String> {
        self.0.find_environment(a, n).await
    }
    async fn create_environment(&self, a: &str, n: &str) -> Result<String, String> {
        self.0.create_environment(a, n).await
    }
    async fn find_profile(&self, a: &str, n: &str) -> Result<Option<String>, String> {
        self.0.find_profile(a, n).await
    }
    async fn create_profile(&self, a: &str, n: &str) -> Result<String, String> {
        self.0.create_profile(a, n).await
    }
    async fn latest_version(&self, a: &str, p: &str) -> Result<Option<(i32, Vec<u8>)>, String> {
        self.0.latest_version(a, p).await
    }
    async fn create_version(&self, a: &str, p: &str, c: Vec<u8>) -> Result<i32, String> {
        self.0.create_version(a, p, c).await
    }
    async fn deploy(&self, a: &str, e: &str, p: &str, v: i32, s: &str) -> Result<i32, String> {
        self.0.deploy(a, e, p, v, s).await
    }
}

#[async_trait]
impl ParameterManagerApi for Shared<FakeParameterManager> {
    async fn parameter_exists(&self, n: &str) -> Result<bool, String> {
        self.0.parameter_exists(n).await
    }
    async fn create_parameter(&self, p: &str, i: &str) -> Result<(), String> {
        self.0.create_parameter(p, i).await
    }
    async fn create_version(&self, p: &str, i: &str, d: Vec<u8>) -> Result<VersionCreated, String> {
        self.0.create_version(p, i, d).await
    }
}

#[async_trait]
impl AppConfigurationApi for Shared<FakeAppConfiguration> {
    async fn get(&self, k: &str, l: &str) -> Result<Option<String>, String> {
        self.0.get(k, l).await
    }
    async fn put(&self, k: &str, l: &str, v: &str) -> Result<(), String> {
        self.0.put(k, l, v).await
    }
}

#[async_trait]
impl Clouds for FakeClouds {
    async fn aws(&self, _region: &str) -> Result<Box<dyn AppConfigApi>, String> {
        Ok(Box::new(Shared(self.aws.clone())))
    }
    async fn gcp(&self) -> Result<Box<dyn ParameterManagerApi>, String> {
        Ok(Box::new(Shared(self.gcp.clone())))
    }
    async fn azure(&self, _endpoint: &str, _env: &str) -> Result<Box<dyn AppConfigurationApi>, String> {
        Ok(Box::new(Shared(self.azure.clone())))
    }
}
