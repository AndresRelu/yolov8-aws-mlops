#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:-kitti-ml}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TRAINING_JOB_NAME="${TRAINING_JOB_NAME:-kitti-yolov8-training-full}"

cd "$ROOT_DIR"

FRONTEND_URL="$(AWS_PROFILE="$AWS_PROFILE" terraform -chdir=terraform output -raw frontend_url)"
API_BASE_URL="$(AWS_PROFILE="$AWS_PROFILE" terraform -chdir=terraform output -raw api_base_url)"

echo "Frontend: $FRONTEND_URL"
curl -fsSI "$FRONTEND_URL" | sed -n '1,8p'

echo
echo "Runtime config:"
curl -fsS "$FRONTEND_URL/config.js"

echo
echo
echo "API health:"
curl -fsS "$API_BASE_URL/health"

echo
echo
echo "Training job:"
AWS_PROFILE="$AWS_PROFILE" aws sagemaker describe-training-job \
  --training-job-name "$TRAINING_JOB_NAME" \
  --region "$AWS_REGION" \
  --query '{Status:TrainingJobStatus,SecondaryStatus:SecondaryStatus,FailureReason:FailureReason,ModelArtifacts:ModelArtifacts.S3ModelArtifacts}' \
  --output table
