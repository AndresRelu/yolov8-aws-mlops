locals {
  ai_tags = {
    Project     = var.project_name
    Phase       = "ai-inference"
    ManagedBy   = "Terraform"
    Environment = var.environment
  }

  api_tags = merge(local.ai_tags, { Phase = "api" })

  sagemaker_source_key = "sagemaker/source/sourcedir.tar.gz"
  model_artifact_key   = "training-output/${aws_sagemaker_training_job.kitti_yolov8_training.training_job_name}/output/model.tar.gz"
  model_artifact_uri   = "s3://${var.model_artifacts_bucket_name}/${local.model_artifact_key}"
  training_image       = var.training_instance_type == "ml.g4dn.xlarge" ? "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.6.0-gpu-py312-cu126-ubuntu22.04-sagemaker" : "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.6.0-cpu-py312-ubuntu22.04-sagemaker"
  inference_image      = var.endpoint_instance_type == "ml.g4dn.xlarge" ? "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-inference:2.6.0-gpu-py312-cu126-ubuntu22.04-sagemaker" : "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-inference:2.6.0-cpu-py312-ubuntu22.04-sagemaker"
}

# ==========================================
# 1. IAM ROLE PARA SAGEMAKER
# ==========================================
resource "aws_iam_role" "sagemaker_role" {
  name = "KittiSageMakerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "sagemaker.amazonaws.com" }
      }
    ]
  })

  tags = local.ai_tags
}

resource "aws_iam_role_policy" "sagemaker_policy" {
  name = "KittiSageMakerPolicy"
  role = aws_iam_role.sagemaker_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.curated_bucket_arn,
          "${var.curated_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          var.model_artifacts_bucket_arn,
          "${var.model_artifacts_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# ==========================================
# 2. EMPAQUETADO DE CODIGO SAGEMAKER
# ==========================================
data "archive_file" "sagemaker_code" {
  type        = "tar.gz"
  output_path = "${path.root}/../build/sourcedir.tar.gz"

  source {
    content  = file("${path.root}/../src/sagemaker/train.py")
    filename = "train.py"
  }

  source {
    content  = file("${path.root}/../src/sagemaker/inference.py")
    filename = "inference.py"
  }

  source {
    content  = file("${path.root}/../src/sagemaker/requirements.txt")
    filename = "requirements.txt"
  }
}

resource "aws_s3_object" "sagemaker_source" {
  bucket = var.model_artifacts_bucket_name
  key    = local.sagemaker_source_key
  source = data.archive_file.sagemaker_code.output_path
  etag   = data.archive_file.sagemaker_code.output_md5
}

# ==========================================
# 3. SAGEMAKER TRAINING + ENDPOINT
# ==========================================
resource "aws_sagemaker_training_job" "kitti_yolov8_training" {
  training_job_name = "kitti-yolov8-training-${var.mode}"
  role_arn          = aws_iam_role.sagemaker_role.arn

  algorithm_specification {
    training_image      = local.training_image
    training_input_mode = "File"
  }

  input_data_config {
    channel_name = "dataset"

    data_source {
      s3_data_source {
        s3_data_type              = "S3Prefix"
        s3_uri                    = "s3://${var.curated_bucket_name}/yolo_dataset/"
        s3_data_distribution_type = "FullyReplicated"
      }
    }
  }

  output_data_config {
    s3_output_path = "s3://${var.model_artifacts_bucket_name}/training-output/"
  }

  resource_config {
    instance_type     = var.training_instance_type
    instance_count    = 1
    volume_size_in_gb = 50
  }

  stopping_condition {
    max_runtime_in_seconds = var.training_max_runtime_seconds
  }

  hyper_parameters = {
    mode                       = var.mode
    sagemaker_program          = "train.py"
    sagemaker_submit_directory = "s3://${var.model_artifacts_bucket_name}/sagemaker/source/sourcedir.tar.gz"
    epochs                     = tostring(var.epochs)
    imgsz                      = tostring(var.training_image_size)
    batch                      = tostring(var.training_batch_size)
    model                      = var.yolo_model
  }

  tags = local.ai_tags

  depends_on = [aws_s3_object.sagemaker_source]
}

resource "terraform_data" "wait_for_training_artifact" {
  input = {
    artifact_bucket   = var.model_artifacts_bucket_name
    artifact_key      = local.model_artifact_key
    aws_region        = var.aws_region
    training_job_name = aws_sagemaker_training_job.kitti_yolov8_training.training_job_name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      aws sagemaker wait training-job-completed-or-stopped \
        --training-job-name "${self.input.training_job_name}" \
        --region "${self.input.aws_region}"

      status="$(aws sagemaker describe-training-job \
        --training-job-name "${self.input.training_job_name}" \
        --region "${self.input.aws_region}" \
        --query TrainingJobStatus \
        --output text)"

      if [ "$status" != "Completed" ]; then
        echo "SageMaker training job ${self.input.training_job_name} ended with status: $status" >&2
        exit 1
      fi

      for attempt in $(seq 1 30); do
        if aws s3api head-object \
          --bucket "${self.input.artifact_bucket}" \
          --key "${self.input.artifact_key}" \
          --region "${self.input.aws_region}" >/dev/null 2>&1; then
          exit 0
        fi

        echo "Waiting for s3://${self.input.artifact_bucket}/${self.input.artifact_key} (attempt $attempt/30)..."
        sleep 10
      done

      echo "Model artifact was not found after waiting: s3://${self.input.artifact_bucket}/${self.input.artifact_key}" >&2
      exit 1
    EOT
  }

  depends_on = [aws_sagemaker_training_job.kitti_yolov8_training]
}

resource "aws_sagemaker_model" "kitti_model" {
  count = var.deploy_sagemaker_endpoint ? 1 : 0

  name               = "kitti-yolov8-model-${var.mode}"
  execution_role_arn = aws_iam_role.sagemaker_role.arn

  primary_container {
    image          = local.inference_image
    model_data_url = local.model_artifact_uri

    environment = {
      SAGEMAKER_PROGRAM             = "inference.py"
      SAGEMAKER_SUBMIT_DIRECTORY    = "s3://${var.model_artifacts_bucket_name}/sagemaker/source/sourcedir.tar.gz"
      SAGEMAKER_CONTAINER_LOG_LEVEL = "20"
      SAGEMAKER_REGION              = var.aws_region
    }
  }

  tags = local.ai_tags

  depends_on = [terraform_data.wait_for_training_artifact]
}

resource "aws_sagemaker_endpoint_configuration" "kitti_endpoint_config" {
  count = var.deploy_sagemaker_endpoint ? 1 : 0

  name = "kitti-yolov8-endpoint-config-${var.mode}"

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.kitti_model[0].name
    instance_type          = var.endpoint_instance_type
    initial_instance_count = 1
  }

  tags = local.ai_tags
}

resource "aws_sagemaker_endpoint" "kitti_endpoint" {
  count = var.deploy_sagemaker_endpoint ? 1 : 0

  name                 = var.sagemaker_endpoint_name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.kitti_endpoint_config[0].name

  tags = local.ai_tags
}

# ==========================================
# 4. LAMBDA API HANDLER
# ==========================================
data "archive_file" "api_handler_zip" {
  type        = "zip"
  source_file = "${path.root}/../src/lambda/api_handler.py"
  output_path = "${path.module}/api_handler.zip"
}

resource "aws_iam_role" "api_lambda_role" {
  name = "KittiApiLambdaRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.api_tags
}

resource "aws_iam_role_policy" "api_lambda_policy" {
  name = "KittiApiLambdaPolicy"
  role = aws_iam_role.api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${var.input_bucket_arn}/incoming/*",
          "${var.raw_bucket_arn}/images/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint",
          "sagemaker:DescribeEndpoint"
        ]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${var.account_id}:endpoint/${var.sagemaker_endpoint_name}"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "rest_api_handler" {
  name              = "/aws/lambda/kitti-rest-api-handler"
  retention_in_days = 14

  tags = local.api_tags
}

resource "aws_lambda_function" "rest_api_handler" {
  function_name    = "kitti-rest-api-handler"
  role             = aws_iam_role.api_lambda_role.arn
  runtime          = "python3.11"
  handler          = "api_handler.lambda_handler"
  filename         = data.archive_file.api_handler_zip.output_path
  source_code_hash = data.archive_file.api_handler_zip.output_base64sha256
  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      SAGEMAKER_ENDPOINT_NAME      = var.sagemaker_endpoint_name
      ALLOWED_IMAGE_BUCKETS        = "${var.input_bucket_name},${var.raw_bucket_name}"
      DEFAULT_CONFIDENCE_THRESHOLD = "0.7"
      MAX_IMAGE_BYTES              = "6000000"
      CORS_ORIGIN                  = var.api_cors_origin
    }
  }

  tags = local.api_tags

  depends_on = [
    aws_cloudwatch_log_group.rest_api_handler,
    aws_iam_role_policy.api_lambda_policy
  ]
}

# ==========================================
# 5. API GATEWAY REST API
# ==========================================
resource "aws_api_gateway_rest_api" "kitti_api" {
  name        = "kitti-ml-rest-api"
  description = "REST API for KITTI YOLOv8 SageMaker inference"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  binary_media_types = [
    "image/png",
    "image/jpeg",
    "application/octet-stream"
  ]

  tags = local.api_tags
}

resource "aws_api_gateway_resource" "predict" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  parent_id   = aws_api_gateway_rest_api.kitti_api.root_resource_id
  path_part   = "predict"
}

resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  parent_id   = aws_api_gateway_rest_api.kitti_api.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "predict_post" {
  rest_api_id      = aws_api_gateway_rest_api.kitti_api.id
  resource_id      = aws_api_gateway_resource.predict.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_method" "health_get" {
  rest_api_id      = aws_api_gateway_rest_api.kitti_api.id
  resource_id      = aws_api_gateway_resource.health.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_method" "predict_options" {
  rest_api_id   = aws_api_gateway_rest_api.kitti_api.id
  resource_id   = aws_api_gateway_resource.predict.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "predict_options" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "predict_options_200" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "predict_options_200" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  status_code = aws_api_gateway_method_response.predict_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,x-api-key'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.api_cors_origin}'"
  }

  depends_on = [aws_api_gateway_integration.predict_options]
}

resource "aws_api_gateway_integration" "predict_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.kitti_api.id
  resource_id             = aws_api_gateway_resource.predict.id
  http_method             = aws_api_gateway_method.predict_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rest_api_handler.invoke_arn
}

resource "aws_api_gateway_integration" "health_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.kitti_api.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.health_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rest_api_handler.invoke_arn
}

resource "aws_lambda_permission" "allow_api_gateway" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rest_api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.kitti_api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "kitti_api" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.predict.id,
      aws_api_gateway_method.predict_post.id,
      aws_api_gateway_method.predict_options.id,
      aws_api_gateway_method_response.predict_options_200.id,
      aws_api_gateway_integration.predict_lambda.id,
      aws_api_gateway_integration.predict_options.id,
      aws_api_gateway_integration_response.predict_options_200.id,
      var.api_cors_origin,
      aws_api_gateway_resource.health.id,
      aws_api_gateway_method.health_get.id,
      aws_api_gateway_integration.health_lambda.id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.predict_lambda,
    aws_api_gateway_integration.health_lambda,
    aws_api_gateway_integration_response.predict_options_200
  ]
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.kitti_api.id
  deployment_id = aws_api_gateway_deployment.kitti_api.id
  stage_name    = var.api_stage_name

  tags = local.api_tags
}

resource "aws_api_gateway_api_key" "kitti_api_key" {
  name    = "kitti-ml-rest-api-key"
  enabled = true

  tags = local.api_tags
}

resource "aws_api_gateway_usage_plan" "kitti_usage_plan" {
  name = "kitti-ml-rest-api-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.kitti_api.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }

  throttle_settings {
    burst_limit = 5
    rate_limit  = 2
  }

  quota_settings {
    limit  = 1000
    period = "MONTH"
  }

  tags = local.api_tags
}

resource "aws_api_gateway_usage_plan_key" "kitti_usage_plan_key" {
  key_id        = aws_api_gateway_api_key.kitti_api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.kitti_usage_plan.id
}
