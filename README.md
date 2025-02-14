# ECS setup with EC2

This repo contains Terraform code to create an ECR registry, a secrets manager, and an ECS cluster with auto-scaling, load balancing, and an EC2 server

## Infrastructure setup

Go into the ECR-SECRETS-MANAGER folder and run the following command
```bash
terraform apply
```
It will create an ECR and a secrets manager where docker images and respective secrets can be placed. Image URL with tag and secrets arn will be needed for the next steps 

After this run the below command form the root location, which will create around 58 resources
```bash
terraform apply
```
We can access the application on the LB's DNS URL
 
## Demo terraform.tfvars values

```javascript
# For ECR and Secrets Manager
region  = "us-east-1"
name    = "dev-ecr"
sm_name = "dev-secrets-manager"
tags = {
  Name = "dev-setup"
}

# For Rest of the infrastructure
region         = "us-east-1"
name           = "Dev"
vpc_cidr       = "10.0.0.0/16"
instance_type  = "t2.micro"
image          = "nginx:latest"
container_name = "application-container"
container_port = 80
host_port      = 80
tags = {
  Name = "Dev"
}
secrets_arn = "arn:aws:secretsmanager:us-east-1:875683986723:secret:dev-secrets-manager209982167543014746400000001"
secret_keys = [
  "KEY_ONE", "KEY_TWO"
]
```


## Destroy Infrastructure

Destroy the ECS and related resoucres first and then destroy ECR and Secrets Manager, to do so run the following command from the respective folders
```bash
terraform destroy
```

While doing terraform destroy it will keep waitng for service state to be in INACTIVE for 20 minutes and then destroy will fail and it will give error like below
```
Error: waiting for ECS Service delete: timeout while waiting for state to become 'INACTIVE' (last state: 'DRAINING', timeout: 20m0s)
```
To counter this error we manully need to click on the delete cluster button on the AWS portal after the last status of the task will go in the stopping state, then terraform destroy will work as usual