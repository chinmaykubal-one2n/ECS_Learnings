data "aws_availability_zones" "available" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "ecs_cluster" {
  source                                = "terraform-aws-modules/ecs/aws//modules/cluster"
  cluster_name                          = "${var.name}-cluster"
  create_cloudwatch_log_group           = false
  default_capacity_provider_use_fargate = false
  create_task_exec_iam_role             = true
  task_exec_iam_role_name               = "task-definition-role"
  autoscaling_capacity_providers = {
    ec_2 = {
      auto_scaling_group_arn         = module.autoscaling["ec_2"].autoscaling_group_arn
      managed_termination_protection = "DISABLED"
      managed_scaling = {
        maximum_scaling_step_size = 1
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 60
      }
      default_capacity_provider_strategy = {
        weight = 60
        base   = 20
      }
    }
  }
  tags = var.tags
}
module "ecs_service" {
  source                   = "terraform-aws-modules/ecs/aws//modules/service"
  version                  = "5.12.0"
  name                     = "${var.name}-service"
  cluster_arn              = module.ecs_cluster.arn
  network_mode             = "bridge"
  cpu                      = 512
  memory                   = 512
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = {
    ec_2 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["ec_2"].name
      weight            = 1
      base              = 1
    }
  }
  deployment_circuit_breaker = {
    enable   = true
    rollback = true
  }
  container_definitions = {
    (var.container_name) = {
      image = var.image
      port_mappings = [
        {
          name          = var.container_name
          containerPort = var.container_port
          hostPort      = var.host_port
          protocol      = "tcp"
        }
      ]
      secrets = [
        for secret_key in var.secret_keys : {
          name      = secret_key
          valueFrom = "${var.secrets_arn}:${secret_key}::"
        }
      ]
      readonly_root_filesystem               = false
      enable_cloudwatch_logging              = false
      create_cloudwatch_log_group            = false
      cloudwatch_log_group_name              = "/aws/ecs/${var.name}/${var.container_name}"
      cloudwatch_log_group_retention_in_days = 7
    }
  }
  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["dev_ecs"].arn
      container_name   = var.container_name
      container_port   = var.container_port
    }
  }
  subnet_ids = module.vpc.private_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = var.container_port
      to_port                  = var.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb.security_group_id
    }
  }
  tags = var.tags
}

data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 6.5"
  for_each = {
    # On-demand instances
    ec_2 = {
      instance_type              = var.instance_type
      use_mixed_instances_policy = false
      mixed_instances_policy     = {}
      user_data                  = <<-EOT
        #!/bin/bash
        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${var.name}-cluster
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(var.tags)}
        ECS_ENABLE_TASK_IAM_ROLE=true
        EOF
      EOT
    }
  }
  create_launch_template = true
  network_interfaces = [
    {
      associate_public_ip_address = true
    }
  ]
  name                            = "${var.name}-${each.key}"
  image_id                        = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type                   = each.value.instance_type
  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(each.value.user_data)
  ignore_desired_capacity_changes = true
  create_iam_instance_profile     = true
  iam_role_name                   = "${var.name}-iam-role"
  iam_role_description            = "ECS role for ${var.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role      = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore             = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonSSMManagedEC2InstanceDefaultPolicy = "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
    AmazonECSTaskExecutionRolePolicy         = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    SecretsManagerReadWrite                  = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
  }
  vpc_zone_identifier = module.vpc.public_subnets
  health_check_type   = "EC2"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }
  protect_from_scale_in = false
  enable_monitoring     = false
  tags                  = var.tags
}

module "autoscaling_sg" {
  source      = "terraform-aws-modules/security-group/aws"
  version     = "~> 5.0"
  name        = "${var.name}-asg-sg"
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id
  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.alb.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1
  egress_rules                                             = ["all-all"]
  tags                                                     = var.tags
}

module "vpc" {
  source          = "terraform-aws-modules/vpc/aws"
  version         = "~> 5.0"
  name            = "${var.name}-vpc"
  cidr            = var.vpc_cidr
  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  tags            = var.tags
}

module "alb" {
  source                     = "terraform-aws-modules/alb/aws"
  version                    = "~> 9.0"
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  vpc_id                     = module.vpc.vpc_id
  subnets                    = module.vpc.public_subnets
  enable_deletion_protection = false
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }
  listeners = {
    ex_http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "dev_ecs"
      }
    }
  }
  target_groups = {
    dev_ecs = {
      backend_protocol                  = "HTTP"
      backend_port                      = var.container_port
      target_type                       = "instance"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true
      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }
      create_attachment = false
    }
  }
  tags = var.tags
}
