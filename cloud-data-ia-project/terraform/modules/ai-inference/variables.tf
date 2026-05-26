variable "aws_region" {
  type        = string
  description = "Region AWS donde se despliegan SageMaker, Lambda y API Gateway"
}

variable "account_id" {
  type        = string
  description = "ID de cuenta AWS usado para armar ARNs con scope minimo"
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto KITTI"
}

variable "environment" {
  type        = string
  description = "Ambiente de ejecucion (dev/prod)"
}

variable "raw_bucket_name" {
  type        = string
  description = "Nombre del bucket S3 RAW"
}

variable "raw_bucket_arn" {
  type        = string
  description = "ARN del bucket S3 RAW"
}

variable "curated_bucket_name" {
  type        = string
  description = "Nombre del bucket S3 Curated"
}

variable "curated_bucket_arn" {
  type        = string
  description = "ARN del bucket S3 Curated"
}

variable "input_bucket_name" {
  type        = string
  description = "Nombre del bucket S3 para imagenes de entrada a la API"
}

variable "input_bucket_arn" {
  type        = string
  description = "ARN del bucket S3 para imagenes de entrada a la API"
}

variable "model_artifacts_bucket_name" {
  type        = string
  description = "Nombre del bucket S3 para artefactos del modelo"
}

variable "model_artifacts_bucket_arn" {
  type        = string
  description = "ARN del bucket S3 para artefactos del modelo"
}

variable "training_instance_type" {
  type        = string
  default     = "ml.m5.xlarge"
  description = "Tipo de instancia para el entrenamiento en SageMaker"
}

variable "endpoint_instance_type" {
  type        = string
  default     = "ml.t2.medium"
  description = "Tipo de instancia para el endpoint real-time de SageMaker"
}

variable "deploy_sagemaker_endpoint" {
  type        = bool
  default     = false
  description = "Controla si se crea el endpoint real-time de SageMaker"
}

variable "sagemaker_endpoint_name" {
  type        = string
  default     = "kitti-yolov8-endpoint"
  description = "Nombre del endpoint real-time de SageMaker"
}

variable "api_stage_name" {
  type        = string
  default     = "dev"
  description = "Stage de API Gateway"
}

variable "api_cors_origin" {
  type        = string
  default     = "*"
  description = "Origen permitido para CORS"
}
