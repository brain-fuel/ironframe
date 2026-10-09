# Runs one twin image on AWS ECS Fargate behind a network load balancer, one TCP listener per port,
# so a wire protocol such as Kafka's reaches it unchanged. ref:DEC-opentofu
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
