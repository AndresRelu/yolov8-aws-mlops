# ==========================================
# 1. CONFIGURACIÓN DE TERRAFORM Y BACKEND
# ==========================================
terraform {
  required_version = ">= 1.8"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }

    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0, < 7.0.0"
    }
  }

  backend "s3" {
    bucket  = "kitti-terraform-state-840584084071"
    key     = "cloud-data-ia-project/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

# ==========================================
# 2. CONFIGURACIÓN DEL PROVEEDOR AWS
# ==========================================
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ==========================================
# 3. DECLARACIÓN DE MÓDULOS DE LA ARQUITECTURA
# ==========================================

# Módulo 1: Almacenamiento (ÚNICO ACTIVO PARA LA FASE A3)
module "storage" {
  source                 = "./modules/storage"
  project_name           = var.project_name
  environment            = var.environment
  raw_bucket_name        = local.raw_bucket_name
  curated_bucket_name    = local.curated_bucket_name
  input_bucket_name      = local.input_bucket_name
  model_artifacts_bucket = local.model_artifacts_bucket
}

# Módulo 2: Ingeniería de Datos (ACTIVO PARA LA FASE A4)
module "data-eng" {
  source                      = "./modules/data-eng"
  project_name                = var.project_name
  environment                 = var.environment
  raw_bucket_name             = local.raw_bucket_name
  curated_bucket_name         = local.curated_bucket_name
  model_artifacts_bucket_name = local.model_artifacts_bucket

  # Mapeo de ARNs dinámicos que provienen del módulo de almacenamiento
  raw_bucket_arn             = module.storage.raw_bucket_arn
  curated_bucket_arn         = module.storage.curated_bucket_arn
  model_artifacts_bucket_arn = module.storage.model_artifacts_bucket_arn

  depends_on = [module.storage]
}


# Módulo 3: AI + Inferencia + API REST (Fase B / B.5)
module "ai-inference" {
  source = "./modules/ai-inference"

  aws_region                = var.aws_region
  account_id                = local.account_id
  project_name              = var.project_name
  environment               = var.environment
  sagemaker_endpoint_name   = var.sagemaker_endpoint_name
  training_instance_type    = var.training_instance_type
  endpoint_instance_type    = var.endpoint_instance_type
  deploy_sagemaker_endpoint = var.deploy_sagemaker_endpoint
  api_stage_name            = var.api_stage_name
  api_cors_origin           = var.api_cors_origin

  raw_bucket_name             = local.raw_bucket_name
  raw_bucket_arn              = module.storage.raw_bucket_arn
  curated_bucket_name         = local.curated_bucket_name
  curated_bucket_arn          = module.storage.curated_bucket_arn
  input_bucket_name           = local.input_bucket_name
  input_bucket_arn            = module.storage.input_bucket_arn
  model_artifacts_bucket_name = local.model_artifacts_bucket
  model_artifacts_bucket_arn  = module.storage.model_artifacts_bucket_arn

  depends_on = [module.storage]
}

module "orchestration" {
  source = "./modules/orchestration"

  aws_region              = var.aws_region
  account_id              = local.account_id
  project_name            = var.project_name
  environment             = var.environment
  notification_email      = var.notification_email
  raw_bucket_name         = local.raw_bucket_name
  raw_bucket_arn          = module.storage.raw_bucket_arn
  curated_bucket_name     = local.curated_bucket_name
  curated_bucket_arn      = module.storage.curated_bucket_arn
  model_artifacts_bucket  = local.model_artifacts_bucket
  glue_crawler_name       = "kitti-labels-crawler"
  glue_job_name           = module.data-eng.glue_job_name
  sagemaker_role_arn      = module.ai-inference.sagemaker_role_arn
  sagemaker_endpoint_name = var.sagemaker_endpoint_name
  training_instance_type  = var.training_instance_type
  endpoint_instance_type  = var.endpoint_instance_type

  depends_on = [module.data-eng, module.ai-inference]
}

module "observability" {
  source = "./modules/observability"

  aws_region                   = var.aws_region
  project_name                 = var.project_name
  environment                  = var.environment
  sns_topic_arn                = module.orchestration.sns_topic_arn
  glue_job_name                = module.data-eng.glue_job_name
  rest_api_name                = "kitti-ml-rest-api"
  api_stage_name               = var.api_stage_name
  api_lambda_name              = "kitti-rest-api-handler"
  prepare_yolo_lambda_name     = module.orchestration.prepare_yolo_lambda_name
  training_results_lambda_name = module.orchestration.training_results_lambda_name
  inference_lambda_name        = "kitti-inference-handler"
  sagemaker_endpoint_name      = var.sagemaker_endpoint_name

  depends_on = [module.orchestration, module.ai-inference]
}
