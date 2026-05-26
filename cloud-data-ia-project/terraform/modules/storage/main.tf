# Local para no repetir los mismos tags en cada recurso de S3
locals {
  s3_tags = {
    Project     = var.project_name
    Phase       = "storage"
    ManagedBy   = "Terraform"
    Environment = var.environment
  }
}

# =========================================================================
# 1. DECLARACIÓN DE LOS 4 BUCKETS S3
# =========================================================================

resource "aws_s3_bucket" "raw" {
  bucket        = var.raw_bucket_name
  force_destroy = true # Permite borrar el bucket con Terraform aunque tenga datos dentro en desarrollo
  tags          = local.s3_tags
}

resource "aws_s3_bucket" "curated" {
  bucket        = var.curated_bucket_name
  force_destroy = true
  tags          = local.s3_tags
}

resource "aws_s3_bucket" "input" {
  bucket        = var.input_bucket_name
  force_destroy = true
  tags          = local.s3_tags
}

resource "aws_s3_bucket" "model_artifacts" {
  bucket        = var.model_artifacts_bucket
  force_destroy = true
  tags          = local.s3_tags
}

# =========================================================================
# 2. CONFIGURACIÓN DE VERSIONADO (Enabled en los 4 buckets)
# =========================================================================

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "curated" {
  bucket = aws_s3_bucket.curated.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "input" {
  bucket = aws_s3_bucket.input.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  versioning_configuration { status = "Enabled" }
}

# =========================================================================
# 3. ENCRIPTACIÓN POR DEFECTO (SSE-S3 AES256)
# =========================================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "curated" {
  bucket = aws_s3_bucket.curated.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "input" {
  bucket = aws_s3_bucket.input.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# =========================================================================
# 4. BLOQUEO DE ACCESO PÚBLICO (Totalmente Privados)
# =========================================================================

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "curated" {
  bucket                  = aws_s3_bucket.curated.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "input" {
  bucket                  = aws_s3_bucket.input.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "model_artifacts" {
  bucket                  = aws_s3_bucket.model_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
# 5. Reglas de Ciclo de Vida (Exclusivo para el bucket RAW)
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "archive-old-kitti-data"
    status = "Enabled"

    # ESTO EVITA EL WARNING: Le dice que aplique a todo el bucket sin filtrar prefijos
    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}