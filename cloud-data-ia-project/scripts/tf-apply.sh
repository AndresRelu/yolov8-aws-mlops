#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:-kitti-ml}"
PLAN_FILE="$ROOT_DIR/terraform/tfplan"

cd "$ROOT_DIR"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "No existe $PLAN_FILE"
  echo "Generalo primero con: bash scripts/tf-plan.sh"
  exit 1
fi

AWS_PROFILE="$AWS_PROFILE" terraform -chdir=terraform apply tfplan
