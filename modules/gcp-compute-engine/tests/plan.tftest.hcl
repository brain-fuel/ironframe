# Plans and applies the module against a mocked Google provider. ref:REQ-modules-plan
mock_provider "google" {
  mock_resource "google_compute_address" {
    defaults = {
      address = "10.1.2.3"
    }
  }
}

variables {
  name               = "kafka-app-staging-kafka"
  image              = "docker.io/lawtwin/kafka:0.1.0"
  ports              = [9092, 9644]
  environment        = { TWIN_CONFIG = "{\"seed\":42}" }
  project            = "kafka-app-staging"
  region             = "europe-west1"
  advertise_variable = "LAWTWIN_ADVERTISE"
}

# ref:REQ-modules-plan
run "the_instance_runs_the_twin_with_its_ports_config_and_advertised_address" {
  command = apply

  assert {
    condition     = strcontains(google_compute_instance.this.metadata["user-data"], "docker run --rm --name twin --env-file /etc/ironframe/twin.env -p 9092:9092 -p 9644:9644 docker.io/lawtwin/kafka:0.1.0")
    error_message = "the instance runs the twin image with every port published"
  }
  assert {
    condition     = strcontains(local.env_file, "TWIN_CONFIG={\"seed\":42}\n") && strcontains(local.env_file, "LAWTWIN_ADVERTISE=10.1.2.3:9092\n")
    error_message = "TWIN_CONFIG and the advertised address reach the container"
  }
  assert {
    condition     = output.endpoint == "10.1.2.3:9092"
    error_message = "the endpoint is the reserved address and the first port"
  }
  assert {
    condition     = google_compute_instance.this.zone == "europe-west1-b" && google_compute_instance.this.boot_disk[0].initialize_params[0].image == "cos-cloud/cos-stable"
    error_message = "the instance runs Container-Optimized OS in the region's zone b"
  }
}

# ref:REQ-modules-plan
run "a_private_twin_has_an_internal_address_and_a_firewall_rule_for_its_ports" {
  command = plan

  assert {
    condition     = google_compute_address.this.address_type == "INTERNAL" && length(google_compute_instance.this.network_interface[0].access_config) == 0
    error_message = "a twin is private unless it is public"
  }
  assert {
    condition     = one([for rule in google_compute_firewall.this.allow : rule.protocol == "tcp" && toset(rule.ports) == toset(["9092", "9644"])])
    error_message = "the firewall opens every port over TCP"
  }
  assert {
    condition     = toset(google_compute_firewall.this.source_ranges) == toset(["10.0.0.0/8"])
    error_message = "only the allowed ranges reach the twin"
  }
}

# ref:REQ-modules-plan
run "a_public_twin_gets_an_external_address" {
  command = plan
  variables {
    public              = true
    allowed_cidr_blocks = ["203.0.113.0/24"]
  }
  assert {
    condition     = google_compute_address.this.address_type == "EXTERNAL" && length(google_compute_instance.this.network_interface[0].access_config) == 1
    error_message = "a public twin has an external address"
  }
}

# ref:REQ-modules-plan
run "a_long_name_is_shortened_within_compute_engine_s_limit" {
  command = plan
  variables {
    name = "a-very-long-project-name-staging-environment-kafka-broker-twin-zz"
  }
  assert {
    condition     = length(google_compute_instance.this.name) <= 63
    error_message = "Compute Engine names are at most 63 characters"
  }
}

# ref:REQ-modules-plan
run "a_multi_line_environment_value_is_refused" {
  command = plan
  variables {
    environment = { TWIN_CONFIG = "{\n}" }
  }
  expect_failures = [var.environment]
}
