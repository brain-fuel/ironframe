# Runs one twin image as a GCP Cloud Run service. Cloud Run serves HTTP and gRPC on one port, so
# this module suits HTTP twins; a raw TCP protocol such as Kafka's needs the AWS or Azure module.
# ref:DEC-opentofu ref:DEC-cloud-run-http-only
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}
