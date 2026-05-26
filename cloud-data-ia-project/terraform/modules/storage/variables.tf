variable "project_name" {
  type        = string
  description = "Nombre del proyecto"
}

variable "environment" {
  type        = string
  description = "Ambiente de despliegue (dev, prod, etc.)"
}

variable "raw_bucket_name" {
  type        = string
  description = "Nombre único del bucket S3 Raw"
}

variable "curated_bucket_name" {
  type        = string
  description = "Nombre único del bucket S3 Curated"
}

variable "input_bucket_name" {
  type        = string
  description = "Nombre único del bucket S3 Input"
}

variable "model_artifacts_bucket" {
  type        = string
  description = "Nombre único del bucket S3 Model Artifacts"
}