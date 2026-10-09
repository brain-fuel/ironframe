locals {
  service_name = length(var.name) <= 49 ? var.name : "${substr(var.name, 0, 40)}-${substr(md5(var.name), 0, 8)}"
}

resource "google_cloud_run_v2_service" "this" {
  name                = local.service_name
  project             = var.project
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }
    containers {
      image = var.image
      ports {
        container_port = var.ports[0]
      }
      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
      }
      dynamic "env" {
        for_each = var.environment
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.public ? 1 : 0
  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
