locals {
  glue_tags = {
    Project     = var.project_name
    Phase       = "data-eng"
    ManagedBy   = "Terraform"
    Environment = var.environment
  }
}

# 1. AWS Glue Catalog Database
resource "aws_glue_catalog_database" "kitti_catalog" {
  name = "kitti_catalog"
}

# 2. IAM Role para la ejecución de AWS Glue
resource "aws_iam_role" "glue_role" {
  name = "KittiGlueRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
      }
    ]
  })
  tags = local.glue_tags
}

# 3. Políticas de IAM detalladas para S3 y CloudWatch
resource "aws_iam_role_policy" "glue_policy" {
  name = "KittiGluePolicy"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Lectura del Bucket Raw (Datos de entrada del Crawler/Job)
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.raw_bucket_arn,
          "${var.raw_bucket_arn}/*"
        ]
      },
      # Escritura en el Bucket Curated (Salida de los archivos Parquet)
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          var.curated_bucket_arn,
          "${var.curated_bucket_arn}/*"
        ]
      },
      # Lectura de Scripts/Model Artifacts
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.model_artifacts_bucket_arn,
          "${var.model_artifacts_bucket_arn}/*"
        ]
      },
      # Permisos para logs continuos en CloudWatch
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      # Métricas de rendimiento
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# Política administrada por AWS para componentes base de Glue
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# 4. S3 Object: Sube de manera automática el script de procesamiento (CORREGIDO)
resource "aws_s3_object" "clean_data_script" {
  bucket = var.model_artifacts_bucket_name
  key    = "glue-scripts/clean_data.py"
  source = "${path.root}/../src/glue/clean_data.py"
  etag   = filemd5("${path.root}/../src/glue/clean_data.py")
}

# 5. AWS Glue Crawler (Para catalogar los archivos raw .txt)
resource "aws_glue_crawler" "kitti_labels_crawler" {
  name          = "kitti-labels-crawler"
  database_name = aws_glue_catalog_database.kitti_catalog.name
  role          = aws_iam_role.glue_role.arn

  s3_target {
    path = "s3://${var.raw_bucket_name}/labels/"
  }
  tags = local.glue_tags
}

# 6. AWS Glue Job (Procesamiento Serverless con Spark)
resource "aws_glue_job" "clean_kitti_labels" {
  name              = "kitti-clean-labels-job"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2

  command {
    name            = "glueetl"
    script_location = "s3://${var.model_artifacts_bucket_name}/glue-scripts/clean_data.py"
  }

  default_arguments = {
    "--RAW_LABELS_PATH"                  = "s3://${var.raw_bucket_name}/labels/"
    "--CURATED_OUTPUT_PATH"              = "s3://${var.curated_bucket_name}/labels_parquet/"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-language"                     = "python"
  }

  tags       = local.glue_tags
  depends_on = [aws_s3_object.clean_data_script]
}
