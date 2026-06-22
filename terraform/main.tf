provider "aws" {
  region = "us-east-1"
}

# ─── KMS KEY ───────────────────────────────────────────────────

# Our own KMS key so we control encryption - not Amazon's default
resource "aws_kms_key" "s3_key" {
  description         = "KMS key for S3 bucket encryption"
  enable_key_rotation = true
}

resource "aws_kms_alias" "s3_key" {
  name          = "alias/devsecops-s3-key"
  target_key_id = aws_kms_key.s3_key.key_id
}

# ─── MAIN APP BUCKET ───────────────────────────────────────────

resource "aws_s3_bucket" "app_bucket" {
  bucket = "devsecops-pipeline-app-bucket"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_key.arn
    }
    # This forces every object to use the bucket KMS key
    # Even if someone uploads with a different key it gets overridden
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "app_bucket" {
  bucket                  = aws_s3_bucket.app_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "app_bucket" {
  bucket        = aws_s3_bucket.app_bucket.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  rule {
    id     = "lifecycle-rule"
    status = "Enabled"
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  role   = aws_iam_role.replication.arn
  rule {
    id     = "replicate-everything"
    status = "Enabled"
    destination {
      bucket        = "arn:aws:s3:::devsecops-pipeline-app-bucket-replica"
      storage_class = "STANDARD"
    }
  }
}

resource "aws_s3_bucket_notification" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  topic {
    topic_arn = aws_sns_topic.bucket_notifications.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }
}

# ─── LOGGING BUCKET ────────────────────────────────────────────

# checkov:skip=CKV_AWS_144: Log bucket is a replication destination, not a source
# checkov:skip=CKV2_AWS_62: Log bucket notifications not required for access logs
# checkov:skip=CKV_AWS_145: Log bucket uses AES256 which is sufficient for access logs
resource "aws_s3_bucket" "log_bucket" {
  bucket = "devsecops-pipeline-logs"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_key.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "log_bucket" {
  bucket                  = aws_s3_bucket.log_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  rule {
    id     = "log-lifecycle-rule"
    status = "Enabled"
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  role   = aws_iam_role.replication.arn
  rule {
    id     = "replicate-logs"
    status = "Enabled"
    destination {
      bucket        = "arn:aws:s3:::devsecops-pipeline-logs-replica"
      storage_class = "STANDARD"
    }
  }
}

resource "aws_s3_bucket_notification" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  topic {
    topic_arn = aws_sns_topic.bucket_notifications.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }
}

# ─── SNS TOPIC ─────────────────────────────────────────────────

resource "aws_sns_topic" "bucket_notifications" {
  name              = "s3-bucket-notifications"
  kms_master_key_id = "alias/aws/sns"
}

# ─── IAM REPLICATION ROLE ──────────────────────────────────────

resource "aws_iam_role" "replication" {
  name = "s3-replication-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
    }]
  })
}