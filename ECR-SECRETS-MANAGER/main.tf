data "aws_caller_identity" "current" {}

module "ecr" {
  source                            = "terraform-aws-modules/ecr/aws"
  version                           = "2.3.1"
  repository_name                   = var.name
  repository_type                   = "private"
  repository_image_tag_mutability   = "IMMUTABLE"
  repository_image_scan_on_push     = true
  repository_read_write_access_arns = [data.aws_caller_identity.current.arn]
  create_lifecycle_policy           = true
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 30 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 30
        },
        action = {
          type = "expire"
        }
      }
    ]
  })
  repository_force_delete = true
  tags                    = var.tags
}

module "secrets_manager" {
  source                  = "terraform-aws-modules/secrets-manager/aws"
  version                 = "1.3.1"
  name_prefix             = var.sm_name
  description             = "Demo Secrets Manager"
  recovery_window_in_days = 0
  create_policy           = true
  block_public_policy     = true
  policy_statements = {
    read = {
      sid = "AllowAccountRead"
      principals = [{
        type        = "AWS"
        identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
      }]
      actions   = ["secretsmanager:GetSecretValue"]
      resources = ["*"]
    }
  }
  # Providing an empty secret value to avoid the error
  secret_string = jsonencode({
    secret_value = ""
  })

  tags = var.tags
}
