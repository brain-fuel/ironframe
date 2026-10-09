locals {
  short_name = "${substr(var.name, 0, 23)}-${substr(md5(var.name), 0, 8)}"
  ports      = { for port in var.ports : tostring(port) => port }
}

data "aws_region" "current" {}

resource "aws_ecs_cluster" "this" {
  name = var.name
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ironframe/${var.name}"
  retention_in_days = 7
}

resource "aws_iam_role" "execution" {
  name_prefix = substr(local.short_name, 0, 32)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  container_definitions = jsonencode([{
    name         = "twin"
    image        = var.image
    essential    = true
    portMappings = [for port in var.ports : { containerPort = port, protocol = "tcp" }]
    environment  = [for key in sort(keys(var.environment)) : { name = key, value = var.environment[key] }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "twin"
      }
    }
  }])
}

resource "aws_security_group" "this" {
  name_prefix = local.short_name
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidr_blocks
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  name               = local.short_name
  load_balancer_type = "network"
  internal           = var.internal
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.this.id]
}

resource "aws_lb_target_group" "this" {
  for_each    = local.ports
  name        = substr("${substr(local.short_name, 0, 26)}-${each.key}", 0, 32)
  port        = each.value
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id
}

resource "aws_lb_listener" "this" {
  for_each          = local.ports
  load_balancer_arn = aws_lb.this.arn
  port              = each.value
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = var.assign_public_ip
  }

  dynamic "load_balancer" {
    for_each = local.ports
    content {
      target_group_arn = aws_lb_target_group.this[load_balancer.key].arn
      container_name   = "twin"
      container_port   = load_balancer.value
    }
  }

  depends_on = [aws_lb_listener.this]
}
