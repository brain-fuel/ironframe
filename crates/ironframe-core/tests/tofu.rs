//! A cloud environment's OpenTofu root deploys each twin through the cloud's module, configures
//! the provider from the environment's inputs, passes each module only the inputs it takes, and
//! outputs every twin's endpoint. ref:DEC-opentofu

mod common;

use ironframe_core::manifest::Manifest;
use ironframe_core::tofu::{RELEASED_MODULES, deployment_name, module_source, root_module};
use std::path::Path;

fn cloud_manifest(runtime: &str, cloud: &str) -> Manifest {
    Manifest::parse(&format!(
        "version: 1\nproject: shop\ndependencies:\n  orders_api:\n    settings: {{ORDERS: '${{endpoint}}'}}\nenvironments:\n  dev:\n    runtime: {runtime}\n    cloud: {cloud}\n    dependencies:\n      orders_api:\n        twin: {{image: lawtwin/http, version: 0.1.0, conformance: L1, ports: [8080], config: {{spec: orders}}}}\n"
    ))
    .unwrap()
}

/// ref:REQ-cloud-root-module
#[test]
fn an_aws_root_configures_the_provider_and_passes_module_inputs() {
    let root = root_module(&common::manifest(), "staging", Path::new("/work/app")).unwrap();
    assert_eq!(root["provider"]["aws"][0], serde_json::json!({"region": "eu-west-1"}));
    assert_eq!(root["terraform"]["required_providers"]["aws"]["source"], "hashicorp/aws");
    let kafka = &root["module"]["twin_kafka"];
    assert_eq!(kafka["source"], "/work/app/../modules/aws-ecs-fargate");
    assert_eq!(kafka["name"], "shop-staging-kafka");
    assert_eq!(kafka["image"], "docker.io/lawtwin/kafka:0.1.0");
    assert_eq!(kafka["ports"], serde_json::json!([9092]));
    assert_eq!(kafka["vpc_id"], "vpc-1");
    assert_eq!(kafka["subnet_ids"], serde_json::json!(["subnet-1", "subnet-2"]));
    assert_eq!(kafka["cpu"], 512);
    assert!(kafka.get("region").is_none(), "region belongs to the provider");
    assert_eq!(kafka["environment"]["TWIN_CONFIG"], "{}");
    assert_eq!(root["output"]["endpoints"]["value"], serde_json::json!({"kafka": "${module.twin_kafka.endpoint}"}));
    assert!(root["module"].get("twin_payments").is_none(), "a real dependency is not deployed");
}

/// ref:REQ-cloud-root-module
#[test]
fn gcp_and_azure_roots_use_their_modules_and_providers() {
    let gcp = root_module(
        &cloud_manifest("gcp", "{project: shop-dev, region: europe-west1, modules: /m}"),
        "dev",
        Path::new("/w"),
    )
    .unwrap();
    assert_eq!(gcp["provider"]["google"][0], serde_json::json!({"project": "shop-dev", "region": "europe-west1"}));
    let module = &gcp["module"]["twin_orders_api"];
    assert_eq!(module["source"], "/m/gcp-cloud-run");
    assert_eq!(module["name"], "shop-dev-orders-api");
    assert_eq!(module["project"], "shop-dev");
    assert_eq!(module["environment"]["TWIN_CONFIG"], r#"{"spec":"orders"}"#);
    let azure = root_module(
        &cloud_manifest("azure", "{location: westeurope, resource_group_name: shop-dev, modules: /m}"),
        "dev",
        Path::new("/w"),
    )
    .unwrap();
    assert_eq!(azure["provider"]["azurerm"][0], serde_json::json!({"features": {}}));
    assert_eq!(azure["module"]["twin_orders_api"]["source"], "/m/azure-container-apps");
    assert_eq!(azure["module"]["twin_orders_api"]["resource_group_name"], "shop-dev");
}

/// ref:REQ-cloud-root-module
#[test]
fn released_modules_are_fetched_from_git_at_the_release_tag() {
    let root = root_module(&cloud_manifest("gcp", "{project: p, region: r}"), "dev", Path::new("/w")).unwrap();
    assert_eq!(
        root["module"]["twin_orders_api"]["source"],
        "git::https://github.com/brain-fuel/ironframe.git//modules/gcp-cloud-run?ref=v0.1.0"
    );
    assert_eq!(
        module_source(RELEASED_MODULES, "aws-ecs-fargate", Path::new("/")),
        "git::https://github.com/brain-fuel/ironframe.git//modules/aws-ecs-fargate?ref=v0.1.0"
    );
    assert_eq!(
        module_source("git::ssh://git@example.com/m.git//modules", "x", Path::new("/")),
        "git::ssh://git@example.com/m.git//modules/x"
    );
    assert_eq!(deployment_name("shop", "dev", "orders_api"), "shop-dev-orders-api");
}

/// ref:REQ-cloud-root-module
#[test]
fn the_example_staging_root_points_at_this_repository_s_modules() {
    let path = common::example_manifest_path();
    let manifest = Manifest::load(&path).unwrap();
    let root = root_module(&manifest, "staging", path.parent().unwrap()).unwrap();
    let source = root["module"]["twin_kafka"]["source"].as_str().unwrap();
    assert!(Path::new(source).join("main.tf").exists(), "{source}");
}
