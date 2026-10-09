variable "name" {
  description = "The deployment's name, project-environment-dependency; shortened with a digest where Cloud Run limits length."
  type        = string
}

variable "image" {
  description = "The twin image with its tag."
  type        = string
}

variable "ports" {
  description = "The container port the twin serves; Cloud Run serves exactly one."
  type        = list(number)
  validation {
    condition     = length(var.ports) == 1
    error_message = "Cloud Run serves one port per service."
  }
}

variable "environment" {
  description = "Environment variables for the container, TWIN_CONFIG included."
  type        = map(string)
  default     = {}
}

variable "project" {
  description = "The GCP project."
  type        = string
}

variable "region" {
  description = "The Cloud Run region."
  type        = string
}

variable "cpu" {
  description = "The container's CPU limit."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "The container's memory limit."
  type        = string
  default     = "512Mi"
}

variable "public" {
  description = "Whether anyone may invoke the service without credentials, as a test environment usually wants."
  type        = bool
  default     = true
}
