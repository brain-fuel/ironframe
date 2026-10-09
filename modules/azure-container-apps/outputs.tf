output "endpoint" {
  description = "host:port for TCP ingress, the HTTPS URL otherwise."
  value       = local.tcp ? "${azurerm_container_app.this.ingress[0].fqdn}:${var.ports[0]}" : "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "host" {
  description = "The app's ingress host name."
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "ports" {
  description = "The port ingress serves on."
  value       = local.tcp ? [var.ports[0]] : [443]
}
