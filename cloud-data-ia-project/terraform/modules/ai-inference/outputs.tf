output "sagemaker_role_arn" {
  value = aws_iam_role.sagemaker_role.arn
}

output "sagemaker_endpoint_name" {
  value = var.sagemaker_endpoint_name
}

output "sagemaker_endpoint_arn" {
  value = var.deploy_sagemaker_endpoint ? aws_sagemaker_endpoint.kitti_endpoint[0].arn : null
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.kitti_api.id
}

output "api_base_url" {
  value = "https://${aws_api_gateway_rest_api.kitti_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.dev.stage_name}"
}

output "api_key_id" {
  value = aws_api_gateway_api_key.kitti_api_key.id
}
