variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "ECR repository name"
  type        = string
  default     = "dev-ecr"
}

variable "sm_name" {
  description = "Secrets Manager name"
  type        = string
  default     = "dev-secrets-manager"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    "Name" = "dev-setup"
  }
}
