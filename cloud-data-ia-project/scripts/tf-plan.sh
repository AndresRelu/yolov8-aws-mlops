#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:-kitti-ml}"

cd "$ROOT_DIR"

AWS_PROFILE="$AWS_PROFILE" terraform -chdir=terraform init
AWS_PROFILE="$AWS_PROFILE" terraform -chdir=terraform validate
rm -f terraform/tfplan
AWS_PROFILE="$AWS_PROFILE" terraform -chdir=terraform plan -out=tfplan "$@"

echo
echo "Plan listo en: $ROOT_DIR/terraform/tfplan"
echo "Aplicalo con: bash scripts/tf-apply.sh"
