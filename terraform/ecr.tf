# ─── ECR ───────────────────────────────────────────────────────
resource "aws_ecr_repository" "main" {
  name                 = "${var.project_name}-app"
  image_tag_mutability = "IMMUTABLE" # a scanned tag can never be overwritten

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = {
    Name = "${var.project_name}-ecr"
  }
}

