variable "aws_region" {
  type = string
}

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "sns_topic_arn" {
  type = string
}

variable "glue_job_name" {
  type = string
}

variable "rest_api_name" {
  type = string
}

variable "api_stage_name" {
  type = string
}

variable "api_lambda_name" {
  type = string
}

variable "prepare_yolo_lambda_name" {
  type = string
}

variable "training_results_lambda_name" {
  type = string
}

variable "inference_lambda_name" {
  type = string
}

variable "sagemaker_endpoint_name" {
  type = string
}
