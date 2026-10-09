# Plans the module against a mocked Google provider. ref:REQ-modules-plan
mock_provider "google" {
  mock_resource "google_cloud_run_v2_service" {
    defaults = {
      uri = "https://orders-twin-abc123-ew.a.run.app"
    }
  }
}

variables {
  name        = "shop-dev-orders-api"
  image       = "docker.io/lawtwin/http:0.1.0"
  ports       = [8080]
  environment = { TWIN_CONFIG = "{}" }
  project     = "shop-dev"
  region      = "europe-west1"
}

# ref:REQ-modules-plan
run "the_service_runs_the_twin_on_its_port_with_its_config" {
  command = plan

  assert {
    condition     = google_cloud_run_v2_service.this.template[0].containers[0].image == "docker.io/lawtwin/http:0.1.0"
    error_message = "the service runs the twin image"
  }
  assert {
    condition     = google_cloud_run_v2_service.this.template[0].containers[0].ports[0].container_port == 8080
    error_message = "the twin's port is the container port"
  }
  assert {
    condition     = one([for e in google_cloud_run_v2_service.this.template[0].containers[0].env : e.value if e.name == "TWIN_CONFIG"]) == "{}"
    error_message = "TWIN_CONFIG reaches the container"
  }
  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public) == 1
    error_message = "a public twin is invocable by anyone"
  }
}

# ref:REQ-modules-plan
run "a_long_name_is_shortened_within_cloud_run_s_limit" {
  command = plan
  variables {
    name = "a-very-long-project-name-staging-environment-orders-api-twin"
  }
  assert {
    condition     = length(google_cloud_run_v2_service.this.name) <= 49
    error_message = "Cloud Run names are at most 49 characters"
  }
}

# ref:REQ-modules-plan
run "more_than_one_port_is_refused" {
  command = plan
  variables {
    ports = [8080, 9090]
  }
  expect_failures = [var.ports]
}
