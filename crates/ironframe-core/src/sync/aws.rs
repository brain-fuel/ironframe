//! AWS AppConfig: the settings become a hosted configuration profile of type `AWS.Freeform`,
//! holding them as JSON, under an application and environment that are created when missing. A new
//! version is written and deployed only when the content differs from the latest version, so a
//! repeated sync starts no deployment. The real calls go through the official AWS SDK for Rust.
//! ref:DEC-config-sync

use super::{SyncError, SyncOutcome, settings_json};
use crate::manifest::AwsAppConfigTarget;
use async_trait::async_trait;
use std::collections::BTreeMap;

/// The deployment strategy used when the target names none: AppConfig's predefined all-at-once.
/// ref:DEC-config-sync
pub const DEFAULT_STRATEGY: &str = "AppConfig.AllAtOnce";

/// The AppConfig calls the sync makes, each returning ids or a reason. ref:DEC-config-sync
#[async_trait]
pub trait AppConfigApi: Send + Sync {
    /// The id of the application named `name`, if there is one.
    async fn find_application(&self, name: &str) -> Result<Option<String>, String>;
    /// Creates an application and returns its id.
    async fn create_application(&self, name: &str) -> Result<String, String>;
    /// The id of the application's environment named `name`, if there is one.
    async fn find_environment(&self, application: &str, name: &str) -> Result<Option<String>, String>;
    /// Creates an environment and returns its id.
    async fn create_environment(&self, application: &str, name: &str) -> Result<String, String>;
    /// The id of the application's configuration profile named `name`, if there is one.
    async fn find_profile(&self, application: &str, name: &str) -> Result<Option<String>, String>;
    /// Creates a hosted, freeform configuration profile and returns its id.
    async fn create_profile(&self, application: &str, name: &str) -> Result<String, String>;
    /// The latest hosted version's number and content, if there is one.
    async fn latest_version(&self, application: &str, profile: &str) -> Result<Option<(i32, Vec<u8>)>, String>;
    /// Creates a hosted version of JSON content and returns its number.
    async fn create_version(&self, application: &str, profile: &str, content: Vec<u8>) -> Result<i32, String>;
    /// Deploys a version to an environment and returns the deployment's number.
    async fn deploy(
        &self,
        application: &str,
        environment: &str,
        profile: &str,
        version: i32,
        strategy: &str,
    ) -> Result<i32, String>;
}

/// Syncs settings into the target's hosted configuration profile. ref:DEC-config-sync
pub async fn sync(
    api: &dyn AppConfigApi,
    target: &AwsAppConfigTarget,
    environment: &str,
    settings: &BTreeMap<String, String>,
) -> Result<SyncOutcome, SyncError> {
    let environment_name = target.environment.as_deref().unwrap_or(environment);
    let fail = |reason: String| SyncError {
        target: super::describe(&crate::manifest::SyncTarget::AwsAppconfig(target.clone()), environment),
        reason,
    };
    let application = match api.find_application(&target.application).await.map_err(fail)? {
        Some(id) => id,
        None => api.create_application(&target.application).await.map_err(fail)?,
    };
    let environment_id = match api.find_environment(&application, environment_name).await.map_err(fail)? {
        Some(id) => id,
        None => api.create_environment(&application, environment_name).await.map_err(fail)?,
    };
    let profile = match api.find_profile(&application, &target.profile).await.map_err(fail)? {
        Some(id) => id,
        None => api.create_profile(&application, &target.profile).await.map_err(fail)?,
    };
    let content = settings_json(settings);
    if let Some((_, latest)) = api.latest_version(&application, &profile).await.map_err(fail)?
        && latest == content
    {
        return Ok(SyncOutcome::Unchanged);
    }
    let version = api.create_version(&application, &profile, content).await.map_err(fail)?;
    let strategy = target.deployment_strategy.as_deref().unwrap_or(DEFAULT_STRATEGY);
    let deployment = api.deploy(&application, &environment_id, &profile, version, strategy).await.map_err(fail)?;
    Ok(SyncOutcome::Updated(format!("version {version}, deployment {deployment}")))
}

/// [`AppConfigApi`] over the official AWS SDK, with credentials from the default provider chain.
/// ref:DEC-config-sync
#[cfg(feature = "aws")]
pub struct SdkAppConfig {
    client: aws_sdk_appconfig::Client,
}

#[cfg(feature = "aws")]
impl SdkAppConfig {
    /// A client for `region`, configured the way the AWS CLI is: environment, profile, SSO or role.
    /// `AWS_ENDPOINT_URL` points it at LocalStack or another emulator.
    pub async fn new(region: &str) -> Self {
        let config = aws_config::from_env().region(aws_config::Region::new(region.to_string())).load().await;
        SdkAppConfig { client: aws_sdk_appconfig::Client::new(&config) }
    }
}

#[cfg(feature = "aws")]
fn reason<E: std::error::Error>(error: E) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(inner) = source {
        text.push_str(": ");
        text.push_str(&inner.to_string());
        source = inner.source();
    }
    text
}

#[cfg(feature = "aws")]
#[async_trait]
impl AppConfigApi for SdkAppConfig {
    async fn find_application(&self, name: &str) -> Result<Option<String>, String> {
        let mut pages = self.client.list_applications().into_paginator().items().send();
        while let Some(item) = pages.next().await {
            let item = item.map_err(reason)?;
            if item.name() == Some(name) {
                return Ok(item.id().map(str::to_string));
            }
        }
        Ok(None)
    }

    async fn create_application(&self, name: &str) -> Result<String, String> {
        let created = self.client.create_application().name(name).send().await.map_err(reason)?;
        created.id().map(str::to_string).ok_or_else(|| "AppConfig returned no application id".into())
    }

    async fn find_environment(&self, application: &str, name: &str) -> Result<Option<String>, String> {
        let mut pages = self.client.list_environments().application_id(application).into_paginator().items().send();
        while let Some(item) = pages.next().await {
            let item = item.map_err(reason)?;
            if item.name() == Some(name) {
                return Ok(item.id().map(str::to_string));
            }
        }
        Ok(None)
    }

    async fn create_environment(&self, application: &str, name: &str) -> Result<String, String> {
        let created =
            self.client.create_environment().application_id(application).name(name).send().await.map_err(reason)?;
        created.id().map(str::to_string).ok_or_else(|| "AppConfig returned no environment id".into())
    }

    async fn find_profile(&self, application: &str, name: &str) -> Result<Option<String>, String> {
        let mut pages =
            self.client.list_configuration_profiles().application_id(application).into_paginator().items().send();
        while let Some(item) = pages.next().await {
            let item = item.map_err(reason)?;
            if item.name() == Some(name) {
                return Ok(item.id().map(str::to_string));
            }
        }
        Ok(None)
    }

    async fn create_profile(&self, application: &str, name: &str) -> Result<String, String> {
        let created = self
            .client
            .create_configuration_profile()
            .application_id(application)
            .name(name)
            .location_uri("hosted")
            .r#type("AWS.Freeform")
            .send()
            .await
            .map_err(reason)?;
        created.id().map(str::to_string).ok_or_else(|| "AppConfig returned no profile id".into())
    }

    async fn latest_version(&self, application: &str, profile: &str) -> Result<Option<(i32, Vec<u8>)>, String> {
        let listed = self
            .client
            .list_hosted_configuration_versions()
            .application_id(application)
            .configuration_profile_id(profile)
            .max_results(1)
            .send()
            .await
            .map_err(reason)?;
        let Some(number) = listed.items().first().map(|v| v.version_number()) else { return Ok(None) };
        let version = self
            .client
            .get_hosted_configuration_version()
            .application_id(application)
            .configuration_profile_id(profile)
            .version_number(number)
            .send()
            .await
            .map_err(reason)?;
        Ok(Some((number, version.content().map(|b| b.as_ref().to_vec()).unwrap_or_default())))
    }

    async fn create_version(&self, application: &str, profile: &str, content: Vec<u8>) -> Result<i32, String> {
        let created = self
            .client
            .create_hosted_configuration_version()
            .application_id(application)
            .configuration_profile_id(profile)
            .content_type("application/json")
            .content(aws_sdk_appconfig::primitives::Blob::new(content))
            .send()
            .await
            .map_err(reason)?;
        Ok(created.version_number())
    }

    async fn deploy(
        &self,
        application: &str,
        environment: &str,
        profile: &str,
        version: i32,
        strategy: &str,
    ) -> Result<i32, String> {
        let started = self
            .client
            .start_deployment()
            .application_id(application)
            .environment_id(environment)
            .configuration_profile_id(profile)
            .configuration_version(version.to_string())
            .deployment_strategy_id(strategy)
            .send()
            .await
            .map_err(reason)?;
        Ok(started.deployment_number())
    }
}
