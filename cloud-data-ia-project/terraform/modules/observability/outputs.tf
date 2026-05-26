output "dashboard_name" {
  value = aws_cloudwatch_dashboard.kitti_dashboard.dashboard_name
}

output "sagemaker_5xx_alarm_name" {
  value = aws_cloudwatch_metric_alarm.sagemaker_5xx.alarm_name
}
