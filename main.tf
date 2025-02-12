terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  region         = "us-east-1"
  name           = "Dev"
  vpc_cidr       = "10.0.0.0/16"
  azs            = slice(data.aws_availability_zones.available.names, 0, 3)
  container_name = "application-container"
  # container_port = 4001
  container_port = 80
  host_port      = 80
  tags = {
    Name = local.name
  }
  # copy the secrets manager ARN very carefully, take the reference from the below
  secrets_arn = "arn:aws:secretsmanager:us-east-1:779583862623:secret:demo-secrets-manager20250206103033986600000001"
  # List of all secret names
  secret_keys = [
    "AZURE_STORAGE_ACCOUNT_ACCESS_KEY_Godspeed", "AZURE_STORAGE_ACCOUNT_ACCESS_KEY_Mindmatrix", "AZURE_STORAGE_ACCOUNT_ACCESS_KEY_Rooman",
    "AZURE_STORAGE_ACCOUNT_NAME_Godspeed", "AZURE_STORAGE_ACCOUNT_NAME_Mindmatrix", "AZURE_STORAGE_ACCOUNT_NAME_Rooman",
    "AZURE_STORAGE_CONNECTION_STRING_Godspeed", "AZURE_STORAGE_CONNECTION_STRING_Mindmatrix", "AZURE_STORAGE_CONNECTION_STRING_Rooman",
    "BREVO_API_KEY", "DB_DATABASE", "DB_HOST", "DB_PASSWORD", "DB_PORT", "DB_USER", "JWT_SECRET_KEY", "NODE_ENV", "PORT",
    "SUPABASE_ANON_KEY", "SUPABASE_PASSWORD", "SUPABASE_TOKEN", "SUPABASE_URL", "STUDENT_ID_ENCRYPTION_KEY",
    "VIDEO_SUMMARY_API_URL", "INTERLEAP_API_KEY", "AZURE_STORAGE_CONNECTION_STRING_Interleap", "AZURE_STORAGE_ACCOUNT_NAME_Interleap",
    "AZURE_STORAGE_ACCOUNT_ACCESS_KEY_Interleap", "GITHUB_CLIENT_ID1", "GITHUB_CLIENT_SECRET1", "AI_API_URL", "AI_API_KEY", "BE_API"
  ]

}

module "ecs_cluster" {
  source       = "terraform-aws-modules/ecs/aws//modules/cluster"
  cluster_name = local.name
  # depends_on                            = [module.autoscaling]
  create_cloudwatch_log_group           = false
  default_capacity_provider_use_fargate = false
  create_task_exec_iam_role             = true
  task_exec_iam_role_name               = "task-definition-role"
  autoscaling_capacity_providers = {
    # On-demand instances
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

  tags = local.tags
}

module "ecs_service" {
  source     = "terraform-aws-modules/ecs/aws//modules/service"
  version    = "5.12.0"
  # depends_on = [module.ecs_cluster, module.alb, module.vpc, module.autoscaling]
  # Service
  name         = "${local.name}-service"
  cluster_arn  = module.ecs_cluster.arn
  network_mode = "bridge"
  cpu          = 512
  memory       = 512
  # force_delete = true
  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = {
    # On-demand instances
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
  # Container definition(s)
  container_definitions = {
    (local.container_name) = {
      # image = "779583862623.dkr.ecr.us-east-1.amazonaws.com/demo-ecr:latest"
      image = "nginx:latest"
      port_mappings = [
        {
          name          = local.container_name
          containerPort = local.container_port
          hostPort      = local.host_port
          protocol      = "tcp"
        }
      ]
      # secrets = [
      #   for secret_key in local.secret_keys : {
      #     name      = secret_key
      #     valueFrom = "${local.secrets_arn}:${secret_key}::"
      #   }
      # ]
      readonly_root_filesystem = false

      # default values are true so comment to enable
      enable_cloudwatch_logging              = false
      create_cloudwatch_log_group            = false
      cloudwatch_log_group_name              = "/aws/ecs/${local.name}/${local.container_name}"
      cloudwatch_log_group_retention_in_days = 7
    }
  }

  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["dev_ecs"].arn
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  subnet_ids = module.vpc.private_subnets
  # security_group_ids = [module.autoscaling_sg.security_group_id]
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb.security_group_id
    }
  }
  tags = local.tags
}

data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "autoscaling" {
  source     = "terraform-aws-modules/autoscaling/aws"
  version    = "~> 6.5"
  # depends_on = [module.vpc, module.autoscaling_sg]
  for_each = {
    # On-demand instances
    ec_2 = {
      instance_type              = "t2.micro"
      use_mixed_instances_policy = false
      mixed_instances_policy     = {}
      user_data                  = <<-EOT
        #!/bin/bash
        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${local.name}
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
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
  name                            = "${local.name}-${each.key}"
  image_id                        = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type                   = each.value.instance_type
  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(each.value.user_data)
  ignore_desired_capacity_changes = true
  create_iam_instance_profile     = true
  iam_role_name                   = local.name
  iam_role_description            = "ECS role for ${local.name}"
  # force_delete                    = true
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
  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }
  # Required for  managed_termination_protection = "DISABLED"
  protect_from_scale_in = false
  enable_monitoring     = false
  tags                  = local.tags

}

module "autoscaling_sg" {
  source      = "terraform-aws-modules/security-group/aws"
  version     = "~> 5.0"
  name        = local.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id
  # depends_on  = [module.vpc, module.alb]
  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.alb.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1
  # ingress_rules                                            = ["http-80-tcp"]
  # ingress_cidr_blocks                                      = ["0.0.0.0/0"]
  egress_rules = ["all-all"]
  tags         = local.tags
}

module "vpc" {
  source          = "terraform-aws-modules/vpc/aws"
  version         = "~> 5.0"
  name            = local.name
  cidr            = local.vpc_cidr
  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  tags            = local.tags
}


module "alb" {
  source                     = "terraform-aws-modules/alb/aws"
  version                    = "~> 9.0"
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  vpc_id                     = module.vpc.vpc_id
  subnets                    = module.vpc.public_subnets
  # depends_on                 = [module.vpc]
  enable_deletion_protection = false
  # Security Group
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
      # -1 means all protocols (TCP, UDP, ICMP, etc.) are allowed.
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
      backend_port                      = local.container_port
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
  tags = local.tags
}



# Error: deleting EC2 Internet Gateway (igw-0ba6c6fe9e19bda8b): 
# detaching EC2 Internet Gateway (igw-0ba6c6fe9e19bda8b) from VPC (vpc-02fd8431ba2630154):
#  operation error EC2: DetachInternetGateway, https response error StatusCode: 400,
#   RequestID: f71ac991-c81a-4bf8-9c3b-1a42f0b7355e, api error DependencyViolation: 
#   Network vpc-02fd8431ba2630154 has some mapped public address(es). Please unmap those public address(es) before detaching the gateway.

# Error: waiting for ECS Service (arn:aws:ecs:us-east-1:779583862623:service/Dev/Dev-service)
#  delete: timeout while waiting for state to become 'INACTIVE' (last state: 'DRAINING', timeout: 20m0s)

# https://discuss.hashicorp.com/t/ecs-srevice-destroy-stuck-issue/58366
# https://stackoverflow.com/questions/68117174/during-terraform-destroy-terraform-is-trying-to-destroy-the-ecs-cluster-before