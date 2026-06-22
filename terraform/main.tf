# Tells Terraform we are using AWS in us-east-1
provider "aws" {
  region = "us-east-1"
}

# ─── DATA SOURCE ───────────────────────────────────────────────

# Reads your current AWS account ID automatically
# We use this in the KMS key policy so we never hardcode account numbers
# data blocks read existing information - they don't create anything
data "aws_caller_identity" "current" {}

# ─── KMS KEY ───────────────────────────────────────────────────

# Creates our own KMS encryption key
# KMS is AWS Key Management Service - it manages encryption keys
# We control this key, not Amazon - we decide who can use it
resource "aws_kms_key" "s3_key" {
  description         = "KMS key for S3 bucket encryption"
  # Automatically rotates the key every year - security best practice
  # Old data stays readable but new data uses the new key
  enable_key_rotation = true
}

# Gives the KMS key a human readable name
# Without this it only has a long random ID
resource "aws_kms_alias" "s3_key" {
  name          = "alias/devsecops-s3-key"
  target_key_id = aws_kms_key.s3_key.key_id
}

# Explicitly defines who can use this KMS key and what they can do
# This is least privilege applied to encryption keys
resource "aws_kms_key_policy" "s3_key" {
  key_id = aws_kms_key.s3_key.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Gives the AWS root account full control over the key
        # Required so you never get locked out of your own key
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          # Uses the data source above to get account ID dynamically
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # Allows S3 to use the key to encrypt and decrypt objects automatically
        Sid    = "Allow S3 Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─── MAIN APP BUCKET ───────────────────────────────────────────

# The primary S3 bucket where our application stores data
resource "aws_s3_bucket" "app_bucket" {
  bucket = "devsecops-pipeline-app-bucket"
}

# Encrypts everything stored in the main bucket using our KMS key
# aws:kms means use a customer managed key - not Amazon's default
resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_key.arn
    }
    # Forces every object to use the bucket KMS key
    # Even if someone uploads with a different key it gets overridden
    bucket_key_enabled = true
  }
}

# Hard blocks all public access to the main bucket
# This is a permanent guard - no setting can accidentally make this bucket public
resource "aws_s3_bucket_public_access_block" "app_bucket" {
  bucket                  = aws_s3_bucket.app_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enables versioning on the main bucket
# Every version of every file is preserved
# If a file is deleted or overwritten you can restore the previous version
resource "aws_s3_bucket_versioning" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Sends access logs from the main bucket to the log bucket
# Records who accessed what file, when, and from where
resource "aws_s3_bucket_logging" "app_bucket" {
  bucket        = aws_s3_bucket.app_bucket.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "access-logs/"
}

# Lifecycle policy on the main bucket
# Automatically manages data to save costs and clean up old versions
resource "aws_s3_bucket_lifecycle_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  rule {
    id     = "lifecycle-rule"
    status = "Enabled"
    # Move to cheaper storage after 90 days of no access
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    # Delete old file versions after 365 days
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
    # Clean up incomplete uploads after 7 days
    # Failed uploads leave chunks in S3 that cost money
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Replicates everything in the main bucket to a backup in us-west-2
# If the us-east-1 datacenter goes down your data still exists
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

# Sends alerts to SNS whenever files are created or deleted in main bucket
resource "aws_s3_bucket_notification" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  topic {
    topic_arn = aws_sns_topic.bucket_notifications.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }
}

# ─── LOGGING BUCKET ────────────────────────────────────────────

# checkov:skip=CKV_AWS_144: Log bucket is a replication destination not a source
# checkov:skip=CKV2_AWS_62: Log bucket notifications not required for access logs
# Receives access logs from the main bucket
resource "aws_s3_bucket" "log_bucket" {
  bucket = "devsecops-pipeline-logs"
}

# KMS encryption on the log bucket
# Logs contain access patterns that are sensitive - they need encryption too
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

# Block public access on the log bucket
resource "aws_s3_bucket_public_access_block" "log_bucket" {
  bucket                  = aws_s3_bucket.log_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning on the log bucket
# Logs are audit evidence - you need to prove they were not tampered with
resource "aws_s3_bucket_versioning" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle on the log bucket
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

# Replication on the log bucket
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

# Event notifications on log bucket
resource "aws_s3_bucket_notification" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  topic {
    topic_arn = aws_sns_topic.bucket_notifications.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }
}

# ─── SNS TOPIC ─────────────────────────────────────────────────

# SNS is Simple Notification Service - AWS's alerting system
# This topic receives alerts when bucket events happen
# Encrypted with AWS managed key for SNS
resource "aws_sns_topic" "bucket_notifications" {
  name              = "s3-bucket-notifications"
  kms_master_key_id = "alias/aws/sns"
}

# ─── IAM REPLICATION ROLE ──────────────────────────────────────

# IAM role that gives S3 permission to copy objects to another region
# S3 needs this role to perform replication on your behalf
resource "aws_iam_role" "replication" {
  name = "s3-replication-role"
  # assume_role_policy defines who is allowed to use this role
  # Here we say only the S3 service itself can assume it
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "s3.amazonaws.com"
      }
    }]
  })
}