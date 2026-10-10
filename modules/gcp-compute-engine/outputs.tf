output "endpoint" {
  description = "host:port of the twin's first port, at the reserved address."
  value       = local.endpoint
}

output "host" {
  description = "The reserved address."
  value       = google_compute_address.this.address
}

output "ports" {
  description = "The ports the twin is reached on."
  value       = var.ports
}
