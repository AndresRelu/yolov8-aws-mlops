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

variable "mode" {
  description = "Modo de entrenamiento del pipeline: sample o full."
  type        = string
  default     = "full"

  validation {
    condition     = contains(["sample", "full"], var.mode)
    error_message = "mode debe ser sample o full."
  }
}

variable "epochs" {
  description = "Epocas para el entrenamiento definitivo. 100 es un punto solido para KITTI con YOLOv8m en GPU."
  type        = number
  default     = 100
}

variable "training_image_size" {
  description = "Tamano de imagen usado por YOLOv8 durante entrenamiento."
  type        = number
  default     = 640
}

variable "training_batch_size" {
  description = "Batch size para entrenamiento YOLOv8m en ml.g4dn.xlarge."
  type        = number
  default     = 8
}

variable "yolo_model" {
  description = "Modelo base de Ultralytics YOLOv8 para entrenamiento definitivo."
  type        = string
  default     = "yolov8m.pt"
}

variable "training_max_runtime_seconds" {
  description = "Runtime maximo del training job. 8h da margen para KITTI full con YOLOv8m."
  type        = number
  default     = 28800
}

variable "training_instance_type" {
  default = "ml.g4dn.xlarge"
}

variable "endpoint_instance_type" {
  default = "ml.g4dn.xlarge"
}

variable "deploy_sagemaker_endpoint" {
  description = "Controla si Terraform debe crear el endpoint real-time de SageMaker."
  type        = bool
  default     = true
}

variable "api_stage_name" {
  default = "dev"
}

variable "api_cors_origin" {
  description = "Override opcional para CORS. Si queda null, se usa el dominio HTTPS de CloudFront."
  type        = string
  default     = null
}

data "aws_caller_identity" "current" {}

locals {
  account_id             = data.aws_caller_identity.current.account_id
  raw_bucket_name        = "kitti-ml-project-raw-${local.account_id}"
  curated_bucket_name    = "kitti-ml-project-curated-${local.account_id}"
  input_bucket_name      = "kitti-ml-project-input-${local.account_id}"
  model_artifacts_bucket = "kitti-ml-project-model-artifacts-${local.account_id}"
  frontend_bucket_name   = "kitti-ml-project-frontend-${local.account_id}"
}
