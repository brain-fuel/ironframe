output "endpoint" {
  description = "host:port of the twin's first port, at the load balancer."
  value       = "${aws_lb.this.dns_name}:${var.ports[0]}"
}

output "host" {
  description = "The load balancer's DNS name."
  value       = aws_lb.this.dns_name
}

output "ports" {
  description = "The ports the load balancer listens on."
  value       = var.ports
}
