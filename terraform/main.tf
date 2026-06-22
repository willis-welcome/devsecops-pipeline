# Tells Terraform we are using AWS in us-east-1
provider "aws" {
  region = "us-east-1"
}

# ─── MAIN APP BUCKET ───────────────────────────────────────────

resource "aws_s3_bucket" "app_bucket" {
  bucket = "devsecops-pipeline-app-bucket"
}

# Encrypts everything in the main bucket using AES256
resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Hard blocks all public access to the main bucket
resource "aws_s3_bucket_public_access_block" "app_bucket" {
  bucket                  = aws_s3_bucket.app_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enables versioning on the main bucket
# Every version of every file is preserved and recoverable
resource "aws_s3_bucket_versioning" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Sends access logs from the main bucket to the log bucket
resource "aws_s3_bucket_logging" "app_bucket" {
  bucket        = aws_s3_bucket.app_bucket.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "access-logs/"
}

# Lifecycle policy on the main bucket
# Moves old data to cheaper storage, cleans up old versions, aborts failed uploads
resource "aws_s3_bucket_lifecycle_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id

  rule {
    id     = "lifecycle-rule"
    status = "Enabled"

    # Move to cheaper storage after 90 days
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    # Delete old file versions after 365 days
    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    # FIX - Abort any failed multipart uploads after 7 days
    # Failed uploads leave incomplete chunks sitting in S3 costing money
    # This cleans them up automatically
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Cross region replication - copies everything to a backup in us-west-2
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

# Event notifications - alerts SNS when files are created or deleted
resource "aws_s3_bucket_notification" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  topic {
    topic_arn = aws_sns_topic.bucket_notifications.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }
}

# ─── LOGGING BUCKET ────────────────────────────────────────────

# Separate bucket that receives access logs from the main bucket
resource "aws_s3_bucket" "log_bucket" {
  bucket = "devsecops-pipeline-logs"
}

# FIX - Encrypt the log bucket too
# Checkov checks every bucket - not just the main one
resource "aws_s3_bucket_server_side_encryption_configuration" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access on the log bucket too
resource "aws_s3_bucket_public_access_block" "log_bucket" {
  bucket                  = aws_s3_bucket.log_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning on the log bucket
resource "aws_s3_bucket_versioning" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle on the log bucket - logs don't need to be kept forever
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

# ─── SNS TOPIC ─────────────────────────────────────────────────

# FIX - Encrypt the SNS topic
# Any message sent to this topic is encrypted at rest
resource "aws_sns_topic" "bucket_notifications" {
  name              = "s3-bucket-notifications"
  # kms_master_key_id tells SNS to encrypt messages using AWS managed KMS key
  kms_master_key_id = "alias/aws/sns"
}

# ─── IAM REPLICATION ROLE ──────────────────────────────────────

# IAM role that gives S3 permission to replicate to another region
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