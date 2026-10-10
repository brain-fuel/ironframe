# Runs one twin image on a GCP Compute Engine instance, Container-Optimized OS with the container
# started by systemd, behind a reserved address and a firewall rule for its TCP ports. Cloud Run
# serves only HTTP, so a twin with a wire protocol of its own, such as Kafka's, runs here.
# ref:DEC-opentofu ref:DEC-gce-for-tcp-twins
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}
