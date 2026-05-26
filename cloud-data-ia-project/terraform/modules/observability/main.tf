locals {
  tags = {
    Project     = var.project_name
    Phase       = "observability"
    ManagedBy   = "Terraform"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.inference_lambda_name}"
  retention_in_days = 7

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "prepare_yolo_logs" {
  name              = "/aws/lambda/${var.prepare_yolo_lambda_name}"
  retention_in_days = 7

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "training_results_logs" {
  name              = "/aws/lambda/${var.training_results_lambda_name}"
  retention_in_days = 7

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "sagemaker_5xx" {
  alarm_name          = "kitti-sagemaker-5xx-rate-high"
  alarm_description   = "SageMaker endpoint returned one or more 5XX errors in a 5 minute window."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Invocation5XXErrors"
  namespace           = "AWS/SageMaker"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    EndpointName = var.sagemaker_endpoint_name
    VariantName  = "AllTraffic"
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = local.tags
}

resource "aws_cloudwatch_dashboard" "kitti_dashboard" {
  dashboard_name = "kitti-ml-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Glue Job Duration"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["Glue", "glue.driver.ExecutorRunTime", "JobName", var.glue_job_name]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "YOLO Dataset Objects"
          region = var.aws_region
          view   = "singleValue"
          metrics = [
            ["KittiMLProject/Storage", "CuratedObjectCount"],
            [".", "YoloTrainImages"],
            [".", "YoloValImages"]
          ]
          period = 300
          stat   = "Maximum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "SageMaker Endpoint"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/SageMaker", "ModelLatency", "EndpointName", var.sagemaker_endpoint_name, "VariantName", "AllTraffic"],
            [".", "Invocation5XXErrors", ".", ".", ".", "."]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "API Gateway"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", var.rest_api_name, "Stage", var.api_stage_name],
            [".", "Latency", ".", ".", ".", "."],
            [".", "4XXError", ".", ".", ".", "."],
            [".", "5XXError", ".", ".", ".", "."]
          ]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Lambda REST API"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.api_lambda_name],
            [".", "Errors", ".", "."],
            [".", "Duration", ".", "."]
          ]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Lambda Prepare YOLO"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.prepare_yolo_lambda_name],
            [".", "Errors", ".", "."],
            [".", "Duration", ".", "."]
          ]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Glue Custom Metrics"
          region = var.aws_region
          view   = "singleValue"
          metrics = [
            ["KittiMLProject/DataEngineering", "ProcessedImages"],
            [".", "FailedImages"],
            [".", "ProcessedAnnotations"],
            [".", "AvgFileSize"]
          ]
          period = 300
          stat   = "Maximum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "Lambda Training Results"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.training_results_lambda_name],
            [".", "Errors", ".", "."],
            [".", "Duration", ".", "."]
          ]
          period = 300
          stat   = "Sum"
        }
      }
    ]
  })
}
