# Runs one twin image on Azure Container Apps, in an environment of its own. HTTP twins use the
# app's HTTPS ingress; a raw TCP protocol such as Kafka's uses TCP ingress, which Azure offers
# only in an environment with its own virtual network subnet. ref:DEC-opentofu
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
  }
}
