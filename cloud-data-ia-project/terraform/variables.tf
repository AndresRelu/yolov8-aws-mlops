variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "kitti-ml-project"
}

variable "environment" {
  default = "dev"
}

variable "notification_email" {
  description = "Email real que confirmara la suscripcion SNS."
  type        = string
}

variable "sagemaker_endpoint_name" {
  default = "kitti-yolov8-endpoint"
}

variable "training_instance_type" {
  default = "ml.m5.xlarge"
}

variable "endpoint_instance_type" {
  default = "ml.t2.medium"
}

variable "deploy_sagemaker_endpoint" {
  description = "Controla si Terraform debe crear el endpoint real-time de SageMaker. Mantener false para evitar costo continuo."
  type        = bool
  default     = false
}

variable "api_stage_name" {
  default = "dev"
}

variable "api_cors_origin" {
  default = "*"
}

data "aws_caller_identity" "current" {}

locals {
  account_id             = data.aws_caller_identity.current.account_id
  raw_bucket_name        = "kitti-ml-project-raw-${local.account_id}"
  curated_bucket_name    = "kitti-ml-project-curated-${local.account_id}"
  input_bucket_name      = "kitti-ml-project-input-${local.account_id}"
  model_artifacts_bucket = "kitti-ml-project-model-artifacts-${local.account_id}"
}
