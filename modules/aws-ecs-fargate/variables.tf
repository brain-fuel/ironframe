variable "name" {
  description = "The deployment's name, project-environment-dependency; shortened with a digest where AWS limits length."
  type        = string
}

variable "image" {
  description = "The twin image with its tag."
  type        = string
}

variable "ports" {
  description = "The container ports the twin serves; each gets a TCP listener of the same number."
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

variable "vpc_id" {
  description = "The VPC the service and load balancer run in."
  type        = string
}

variable "subnet_ids" {
  description = "The subnets of the tasks and the load balancer."
  type        = list(string)
}

variable "cpu" {
  description = "Fargate CPU units for the task."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate memory for the task, in MiB."
  type        = number
  default     = 512
}

variable "assign_public_ip" {
  description = "Whether tasks get a public IP, which subnets without a NAT gateway need to pull images."
  type        = bool
  default     = true
}

variable "internal" {
  description = "Whether the load balancer is internal to the VPC."
  type        = bool
  default     = false
}

variable "allowed_cidr_blocks" {
  description = "The networks allowed to reach the twin's ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
