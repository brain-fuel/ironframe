output "endpoint" {
  description = "The service's HTTPS URL."
  value       = google_cloud_run_v2_service.this.uri
}

output "host" {
  description = "The service's host name."
  value       = trimprefix(google_cloud_run_v2_service.this.uri, "https://")
}

output "ports" {
  description = "The port Cloud Run serves on."
  value       = [443]
}
