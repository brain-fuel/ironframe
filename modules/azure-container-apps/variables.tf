variable "name" {
  description = "The deployment's name, project-environment-dependency; shortened with a digest where Azure limits length."
  type        = string
}

variable "image" {
  description = "The twin image with its tag."
  type        = string
}

variable "ports" {
  description = "The container ports the twin serves; ingress exposes the first."
  type        = list(number)
  validation {
    condition     = length(var.ports) > 0
    error_message = "A twin serves at least one port."
  }
}

variable "environment" {
  description = "Environment variables for the container, TWIN_CONFIG included."
  type        = map(string)
  default     = {}
}

variable "location" {
  description = "The Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "The resource group the environment and app are created in."
  type        = string
}

variable "cpu" {
  description = "The container's CPU cores."
  type        = number
  default     = 0.5
}

variable "memory" {
  description = "The container's memory, matching the CPU as Container Apps requires."
  type        = string
  default     = "1Gi"
}

variable "transport" {
  description = "Ingress transport: http for HTTP twins, tcp for wire protocols such as Kafka's."
  type        = string
  default     = "http"
  validation {
    condition     = contains(["http", "http2", "tcp"], var.transport)
    error_message = "transport is http, http2 or tcp."
  }
}

variable "infrastructure_subnet_id" {
  description = "A subnet for the Container Apps environment, which TCP ingress requires."
  type        = string
  default     = null
}

variable "external" {
  description = "Whether ingress is reachable from outside the environment."
  type        = bool
  default     = true
}
