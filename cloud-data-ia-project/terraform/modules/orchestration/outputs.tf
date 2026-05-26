output "state_machine_arn" {
  value = aws_sfn_state_machine.kitti_pipeline.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.detections.arn
}

output "prepare_yolo_lambda_name" {
  value = aws_lambda_function.prepare_yolo_dataset.function_name
}

output "prepare_yolo_lambda_arn" {
  value = aws_lambda_function.prepare_yolo_dataset.arn
}

output "training_results_lambda_name" {
  value = aws_lambda_function.training_results_notifier.function_name
}

output "training_results_lambda_arn" {
  value = aws_lambda_function.training_results_notifier.arn
}
