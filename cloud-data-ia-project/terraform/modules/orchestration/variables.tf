variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "notification_email" {
  type = string
}

variable "raw_bucket_name" {
  type = string
}

variable "raw_bucket_arn" {
  type = string
}

variable "curated_bucket_name" {
  type = string
}

variable "curated_bucket_arn" {
  type = string
}

variable "model_artifacts_bucket" {
  type = string
}

variable "glue_crawler_name" {
  type = string
}

variable "glue_job_name" {
  type = string
}

variable "sagemaker_role_arn" {
  type = string
}

variable "sagemaker_endpoint_name" {
  type = string
}

variable "mode" {
  type = string
}

variable "epochs" {
  type = number
}

variable "training_image_size" {
  type = number
}

variable "training_batch_size" {
  type = number
}

variable "yolo_model" {
  type = string
}

variable "training_max_runtime_seconds" {
  type = number
}

variable "training_instance_type" {
  type = string
}

variable "endpoint_instance_type" {
  type = string
}

variable "deploy_sagemaker_endpoint" {
  type = bool
}
