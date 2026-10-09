# Plans the module against a mocked AWS provider, so the plan's shape is checked without an
# account. ref:REQ-modules-plan
mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "eu-west-1"
      name   = "eu-west-1"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/ironframe-test"
    }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/x/1"
      dns_name = "x-1.elb.eu-west-1.amazonaws.com"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/x/1"
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:eu-west-1:123456789012:task-definition/x:1"
    }
  }
}

variables {
  name        = "kafka-app-staging-kafka"
  image       = "docker.io/lawtwin/kafka:0.1.0"
  ports       = [9092, 9644]
  environment = { TWIN_CONFIG = "{\"seed\":42}" }
  vpc_id      = "vpc-1"
  subnet_ids  = ["subnet-1", "subnet-2"]
}

# ref:REQ-modules-plan
run "a_twin_gets_one_tcp_listener_and_target_group_per_port" {
  command = plan

  assert {
    condition     = length(aws_lb_listener.this) == 2 && aws_lb_listener.this["9644"].port == 9644
    error_message = "every port needs its own listener"
  }
  assert {
    condition     = alltrue([for group in aws_lb_target_group.this : group.protocol == "TCP" && length(group.name) <= 32])
    error_message = "target groups are TCP and within AWS's name limit"
  }
  assert {
    condition     = aws_lb.this.load_balancer_type == "network" && length(aws_lb.this.name) <= 32
    error_message = "a network load balancer carries raw TCP"
  }
}

# ref:REQ-modules-plan
run "the_container_receives_the_image_ports_and_twin_config" {
  command = plan

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == "docker.io/lawtwin/kafka:0.1.0"
    error_message = "the task runs the twin image"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment[0].name == "TWIN_CONFIG"
    error_message = "TWIN_CONFIG reaches the container"
  }
  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].portMappings) == 2
    error_message = "every port is mapped"
  }
}

# ref:REQ-modules-plan
run "a_twin_without_ports_is_refused" {
  command = plan
  variables {
    ports = []
  }
  expect_failures = [var.ports]
}
