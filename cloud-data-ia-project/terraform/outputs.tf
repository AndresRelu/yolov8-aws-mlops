# ==========================================
# OUTPUTS DE ALMACENAMIENTO (S3)
# ==========================================
output "raw_bucket_uri" {
  description = "URI del bucket de S3 para datos crudos (KITTI original)."
  value       = "s3://${local.raw_bucket_name}"
}

output "curated_bucket_uri" {
  description = "URI del bucket de S3 para datos procesados y limpios."
  value       = "s3://${local.curated_bucket_name}"
}

output "input_bucket_uri" {
  description = "URI del bucket de S3 con datos listos para el entrenamiento de YOLO."
  value       = "s3://${local.input_bucket_name}"
}

output "model_artifacts_bucket_uri" {
  description = "URI del bucket de S3 donde SageMaker guardará los pesos (.pt / .tar.gz) del modelo."
  value       = "s3://${local.model_artifacts_bucket}"
}

output "sagemaker_endpoint_name" {
  description = "Nombre del endpoint de SageMaker usado por la API REST."
  value       = module.ai-inference.sagemaker_endpoint_name
}

output "api_base_url" {
  description = "Base URL de API Gateway para health y predict."
  value       = module.ai-inference.api_base_url
}

output "api_key_id" {
  description = "ID de la API key; usa AWS CLI con --include-value para ver el secreto."
  value       = module.ai-inference.api_key_id
}

output "step_function_arn" {
  description = "ARN de la state machine principal de orquestacion."
  value       = module.orchestration.state_machine_arn
}

output "sns_topic_arn" {
  description = "ARN del topic SNS para notificaciones del pipeline."
  value       = module.orchestration.sns_topic_arn
}

output "training_results_lambda_name" {
  description = "Lambda que extrae results.png/results.csv del model.tar.gz y manda links por SNS."
  value       = module.orchestration.training_results_lambda_name
}

output "cloudwatch_dashboard_name" {
  description = "Nombre del dashboard CloudWatch del proyecto."
  value       = module.observability.dashboard_name
}
