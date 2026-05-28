variable "project_name" {
  type        = string
  description = "Nombre del proyecto KITTI"
}

variable "environment" {
  type        = string
  description = "Ambiente de ejecucion"
}

variable "frontend_bucket_name" {
  type        = string
  description = "Bucket S3 que almacena el frontend estatico"
}

variable "frontend_source_dir" {
  type        = string
  description = "Directorio local con index.html, app.js y styles.css"
}
