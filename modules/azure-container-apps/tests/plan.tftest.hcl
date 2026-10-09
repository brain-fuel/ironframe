# Plans the module against a mocked Azure provider. ref:REQ-modules-plan
mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shop-dev/providers/Microsoft.OperationalInsights/workspaces/x"
    }
  }
  mock_resource "azurerm_container_app_environment" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shop-dev/providers/Microsoft.App/managedEnvironments/x"
    }
  }
}

variables {
  name                = "kafka-app-staging-kafka"
  image               = "docker.io/lawtwin/kafka:0.1.0"
  ports               = [9092]
  environment         = { TWIN_CONFIG = "{}" }
  location            = "westeurope"
  resource_group_name = "shop-dev"
}

# ref:REQ-modules-plan
run "an_http_twin_gets_https_ingress_on_its_port" {
  command = plan

  assert {
    condition     = azurerm_container_app.this.ingress[0].target_port == 9092 && azurerm_container_app.this.ingress[0].transport == "http"
    error_message = "ingress targets the twin's port"
  }
  assert {
    condition     = azurerm_container_app.this.template[0].container[0].image == "docker.io/lawtwin/kafka:0.1.0"
    error_message = "the app runs the twin image"
  }
  assert {
    condition     = length(azurerm_container_app.this.name) <= 32
    error_message = "Container Apps names are at most 32 characters"
  }
}

# ref:REQ-modules-plan
run "tcp_ingress_without_a_subnet_is_refused" {
  command = plan
  variables {
    transport = "tcp"
  }
  expect_failures = [azurerm_container_app_environment.this]
}

# ref:REQ-modules-plan
run "tcp_ingress_exposes_the_twin_s_port" {
  command = plan
  variables {
    transport                = "tcp"
    infrastructure_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shop-dev/providers/Microsoft.Network/virtualNetworks/v/subnets/apps"
  }
  assert {
    condition     = azurerm_container_app.this.ingress[0].exposed_port == 9092
    error_message = "TCP ingress exposes the twin's own port"
  }
}
