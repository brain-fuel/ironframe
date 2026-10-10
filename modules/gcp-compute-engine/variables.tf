variable "name" {
  description = "The deployment's name, project-environment-dependency; shortened with a digest where Compute Engine limits length."
  type        = string
}

variable "image" {
  description = "The twin image with its tag."
  type        = string
}

variable "ports" {
  description = "The container ports the twin serves, each published on the instance under the same number; the first is the endpoint's."
  type        = list(number)
  validation {
    condition     = length(var.ports) > 0
    error_message = "A twin serves at least one port."
  }
}

variable "environment" {
  description = "Environment variables for the container, TWIN_CONFIG included; each value on one line."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for value in values(var.environment) : !strcontains(value, "\n")])
    error_message = "An environment value must fit on one line."
  }
}

variable "project" {
  description = "The GCP project."
  type        = string
}

variable "region" {
  description = "The region of the reserved address."
  type        = string
}

variable "zone" {
  description = "The instance's zone; the region's zone b when null."
  type        = string
  default     = null
}

variable "machine_type" {
  description = "The instance's machine type."
  type        = string
  default     = "e2-small"
}

variable "network" {
  description = "The VPC network of the instance and its firewall rule."
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "The subnetwork of the instance and its internal address; the network's subnetwork in the region when null."
  type        = string
  default     = null
}

variable "allowed_cidr_blocks" {
  description = "The source ranges allowed to reach the twin's ports."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "public" {
  description = "Whether the twin gets an external address; otherwise it is reached at an internal one, from inside the VPC."
  type        = bool
  default     = false
}

variable "advertise_variable" {
  description = "An environment variable the twin reads the address to advertise from, set to the endpoint's host:port; none when null."
  type        = string
  default     = null
}
