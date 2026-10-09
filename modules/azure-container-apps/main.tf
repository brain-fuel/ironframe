locals {
  short_name = length(var.name) <= 32 ? var.name : "${substr(var.name, 0, 23)}-${substr(md5(var.name), 0, 8)}"
  tcp        = var.transport == "tcp"
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${local.short_name}-logs"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "this" {
  name                       = local.short_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = var.infrastructure_subnet_id

  lifecycle {
    precondition {
      condition     = !local.tcp || var.infrastructure_subnet_id != null
      error_message = "TCP ingress needs infrastructure_subnet_id: Azure offers it only in an environment with its own subnet."
    }
  }
}

resource "azurerm_container_app" "this" {
  name                         = local.short_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  template {
    min_replicas = 1
    max_replicas = 1
    container {
      name   = "twin"
      image  = var.image
      cpu    = var.cpu
      memory = var.memory
      dynamic "env" {
        for_each = var.environment
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  ingress {
    external_enabled = var.external
    target_port      = var.ports[0]
    exposed_port     = local.tcp ? var.ports[0] : null
    transport        = var.transport
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}
