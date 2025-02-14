variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name of the application"
  type        = string
  default     = "Dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}


variable "container_name" {
  description = "Container name"
  type        = string
  default     = "application-container"
}

variable "container_port" {
  description = "Container port"
  type        = number
  default     = 80
}

variable "host_port" {
  description = "Host port"
  type        = number
  default     = 80
}

variable "image" {
  description = "Name of the Docker Image"
  type        = string
  default     = "nginx:latest"
}

variable "instance_type" {
  description = "Type of instance"
  type        = string
  default     = "t2.micro"
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default = {
    "Name" = "Dev"
  }
}

variable "secrets_arn" {
  description = "Secrets Manager ARN"
  type        = string
  default     = null
}

variable "secret_keys" {
  description = "List of secret keys"
  type        = list(string)
  default     = []
}
