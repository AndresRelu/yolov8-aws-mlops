#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

mkdir -p build/sagemaker_source
cp src/sagemaker/train.py build/sagemaker_source/train.py
cp src/sagemaker/inference.py build/sagemaker_source/inference.py
cp src/sagemaker/requirements.txt build/sagemaker_source/requirements.txt

tar -czf build/sourcedir.tar.gz -C build/sagemaker_source .
echo "📦 ¡Éxito! Archivo build/sourcedir.tar.gz creado correctamente para SageMaker."
