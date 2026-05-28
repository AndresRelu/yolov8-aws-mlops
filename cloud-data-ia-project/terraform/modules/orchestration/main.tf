locals {
  tags = {
    Project     = var.project_name
    Phase       = "orchestration"
    ManagedBy   = "Terraform"
    Environment = var.environment
  }

  glue_crawler_arn     = "arn:aws:glue:${var.aws_region}:${var.account_id}:crawler/${var.glue_crawler_name}"
  glue_job_arn         = "arn:aws:glue:${var.aws_region}:${var.account_id}:job/${var.glue_job_name}"
  dataset_uri          = "s3://${var.curated_bucket_name}/yolo_dataset/"
  model_artifacts_arn  = "arn:aws:s3:::${var.model_artifacts_bucket}"
  sagemaker_source_uri = "s3://${var.model_artifacts_bucket}/sagemaker/source/sourcedir.tar.gz"
  training_output_uri  = "s3://${var.model_artifacts_bucket}/training-output/"
  training_image       = var.training_instance_type == "ml.g4dn.xlarge" ? "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.6.0-gpu-py312-cu126-ubuntu22.04-sagemaker" : "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.6.0-cpu-py312-ubuntu22.04-sagemaker"
  inference_image      = var.endpoint_instance_type == "ml.g4dn.xlarge" ? "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-inference:2.6.0-gpu-py312-cu126-ubuntu22.04-sagemaker" : "763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-inference:2.6.0-cpu-py312-ubuntu22.04-sagemaker"
}

resource "aws_sns_topic" "detections" {
  name = "kitti-detections"

  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.detections.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_iam_role" "prepare_yolo_lambda_role" {
  name = "KittiPrepareYoloLambdaRole"

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

  tags = local.tags
}

resource "aws_iam_role_policy" "prepare_yolo_lambda_policy" {
  name = "KittiPrepareYoloLambdaPolicy"
  role = aws_iam_role.prepare_yolo_lambda_role.id

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
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.raw_bucket_arn,
          "${var.raw_bucket_arn}/*",
          var.curated_bucket_arn,
          "${var.curated_bucket_arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "KittiMLProject/Storage"
          }
        }
      }
    ]
  })
}

data "archive_file" "prepare_yolo_handler_zip" {
  type        = "zip"
  source_file = "${path.root}/../src/lambda/prepare_yolo_handler.py"
  output_path = "${path.module}/prepare_yolo_handler.zip"
}

resource "aws_lambda_function" "prepare_yolo_dataset" {
  function_name    = "kitti-prepare-yolo-dataset"
  role             = aws_iam_role.prepare_yolo_lambda_role.arn
  runtime          = "python3.11"
  handler          = "prepare_yolo_handler.lambda_handler"
  filename         = data.archive_file.prepare_yolo_handler_zip.output_path
  source_code_hash = data.archive_file.prepare_yolo_handler_zip.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      RAW_BUCKET              = var.raw_bucket_name
      CURATED_BUCKET          = var.curated_bucket_name
      DEFAULT_DEPLOY_ENDPOINT = tostring(var.deploy_sagemaker_endpoint)
      DEFAULT_MODE            = var.mode
      DEFAULT_SAMPLE_SIZE     = "100"
      YOLO_PREFIX             = "yolo_dataset/"
    }
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.prepare_yolo_lambda_policy]
}

resource "aws_iam_role" "training_results_lambda_role" {
  name = "KittiTrainingResultsLambdaRole"

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

  tags = local.tags
}

resource "aws_iam_role_policy" "training_results_lambda_policy" {
  name = "KittiTrainingResultsLambdaPolicy"
  role = aws_iam_role.training_results_lambda_role.id

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
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${local.model_artifacts_arn}/training-output/*",
          "${local.model_artifacts_arn}/training-results/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.detections.arn
      },
      {
        Effect   = "Allow"
        Action   = "sagemaker:DescribeTrainingJob"
        Resource = "arn:aws:sagemaker:${var.aws_region}:${var.account_id}:training-job/kitti-yolov8-training*"
      }
    ]
  })
}

data "archive_file" "training_results_notifier_zip" {
  type        = "zip"
  source_file = "${path.root}/../src/lambda/training_results_notifier.py"
  output_path = "${path.module}/training_results_notifier.zip"
}

resource "aws_lambda_function" "training_results_notifier" {
  function_name    = "kitti-training-results-notifier"
  role             = aws_iam_role.training_results_lambda_role.arn
  runtime          = "python3.11"
  handler          = "training_results_notifier.lambda_handler"
  filename         = data.archive_file.training_results_notifier_zip.output_path
  source_code_hash = data.archive_file.training_results_notifier_zip.output_base64sha256
  timeout          = 120
  memory_size      = 512

  environment {
    variables = {
      MODEL_ARTIFACTS_BUCKET        = var.model_artifacts_bucket
      PRESIGNED_URL_EXPIRES_SECONDS = "604800"
      RESULTS_PREFIX                = "training-results/"
      SNS_TOPIC_ARN                 = aws_sns_topic.detections.arn
      TRAINING_OUTPUT_PREFIX        = "training-output/"
    }
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.training_results_lambda_policy]
}

resource "aws_cloudwatch_log_group" "step_functions_logs" {
  name              = "/aws/vendedlogs/states/kitti-ml-pipeline"
  retention_in_days = 7

  tags = local.tags
}

resource "aws_iam_role" "step_functions_role" {
  name = "KittiStepFunctionsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "step_functions_policy" {
  name = "KittiStepFunctionsPolicy"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler"
        ]
        Resource = local.glue_crawler_arn
      },
      {
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns",
          "glue:BatchStopJobRun"
        ]
        Resource = local.glue_job_arn
      },
      {
        Effect = "Allow"
        Action = "lambda:InvokeFunction"
        Resource = [
          aws_lambda_function.prepare_yolo_dataset.arn,
          aws_lambda_function.training_results_notifier.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateTrainingJob",
          "sagemaker:DescribeTrainingJob",
          "sagemaker:StopTrainingJob",
          "sagemaker:CreateModel",
          "sagemaker:CreateEndpointConfig",
          "sagemaker:UpdateEndpoint",
          "sagemaker:DescribeEndpoint",
          "sagemaker:AddTags"
        ]
        Resource = [
          "arn:aws:sagemaker:${var.aws_region}:${var.account_id}:training-job/kitti-yolov8-training-*",
          "arn:aws:sagemaker:${var.aws_region}:${var.account_id}:model/kitti-yolov8-model-*",
          "arn:aws:sagemaker:${var.aws_region}:${var.account_id}:endpoint-config/kitti-y8-epc-*",
          "arn:aws:sagemaker:${var.aws_region}:${var.account_id}:endpoint/${var.sagemaker_endpoint_name}"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.sagemaker_role_arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.detections.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:PutTargets",
          "events:DescribeRule"
        ]
        Resource = "arn:aws:events:${var.aws_region}:${var.account_id}:rule/StepFunctionsGetEventsFor*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "kitti_pipeline" {
  name     = "kitti-ml-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn
  type     = "STANDARD"

  definition = templatefile("${path.root}/../src/step_functions/workflow.json", {
    aws_region                   = var.aws_region
    dataset_uri                  = local.dataset_uri
    endpoint_instance_type       = var.endpoint_instance_type
    glue_crawler_name            = var.glue_crawler_name
    glue_job_name                = var.glue_job_name
    inference_image              = local.inference_image
    prepare_yolo_lambda_arn      = aws_lambda_function.prepare_yolo_dataset.arn
    sagemaker_endpoint_name      = var.sagemaker_endpoint_name
    sagemaker_role_arn           = var.sagemaker_role_arn
    sagemaker_source_uri         = local.sagemaker_source_uri
    sns_topic_arn                = aws_sns_topic.detections.arn
    mode                         = var.mode
    epochs                       = var.epochs
    training_image_size          = var.training_image_size
    training_batch_size          = var.training_batch_size
    yolo_model                   = var.yolo_model
    training_max_runtime_seconds = var.training_max_runtime_seconds
    training_image               = local.training_image
    training_instance_type       = var.training_instance_type
    training_results_lambda_arn  = aws_lambda_function.training_results_notifier.arn
    training_output_uri          = local.training_output_uri
  })

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.step_functions_logs.arn}:*"
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.step_functions_policy]
}
