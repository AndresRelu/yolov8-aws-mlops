output "raw_bucket_arn" {
  value = aws_s3_bucket.raw.arn
}

output "curated_bucket_arn" {
  value = aws_s3_bucket.curated.arn
}

output "input_bucket_arn" {
  value = aws_s3_bucket.input.arn
}

output "model_artifacts_bucket_arn" {
  value = aws_s3_bucket.model_artifacts.arn
}