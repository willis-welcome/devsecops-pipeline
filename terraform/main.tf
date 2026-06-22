# Tells Terraform we are using AWS in us-east-1
provider "aws" {
  region = "us-east-1"
}

# The S3 bucket resource - our storage container
resource "aws_s3_bucket" "app_bucket" {
  bucket = "devsecops-pipeline-app-bucket"
}

# FIX 1 - Encrypts everything stored in the bucket using KMS
# KMS is AWS Key Management Service - it manages the encryption keys
# Even if someone accesses the raw files they cannot read them
resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      # AES256 is the encryption algorithm - military grade encryption
      sse_algorithm = "AES256"
    }
  }
}

# FIX 2 - Blocks all public access to this bucket
# This is a hard stop - no setting anywhere can accidentally make this bucket public
resource "aws_s3_bucket_public_access_block" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id

  # Block any public access control lists
  block_public_acls       = true
  # Block any public bucket policies
  block_public_policy     = true
  # Ignore any public access control lists
  ignore_public_acls      = true
  # Restrict any public bucket policies
  restrict_public_buckets = true
}

# FIX 3 - Turns on access logging
# Every request to this bucket gets recorded in a separate logging bucket
# Who accessed it, when, from where - full audit trail
resource "aws_s3_bucket" "log_bucket" {
  bucket = "devsecops-pipeline-logs"
}

resource "aws_s3_bucket_logging" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  # Send all logs to our logging bucket
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "access-logs/"
}

# FIX 4 - Enables versioning
# Every version of every file is preserved
# If a file is deleted or overwritten you can restore the previous version
resource "aws_s3_bucket_versioning" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# FIX 5 - Cross region replication requires versioning first (already enabled above)
# Tells AWS to copy everything to a backup bucket in a second region
resource "aws_s3_bucket_replication_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  # IAM role that gives S3 permission to replicate to the other region
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replicate-everything"
    status = "Enabled"
    destination {
      # The backup bucket in us-west-2 - a completely different datacenter
      bucket        = "arn:aws:s3:::devsecops-pipeline-app-bucket-replica"
      storage_class = "STANDARD"
    }
  }
}

# The IAM role that allows S3 to perform replication
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

# FIX 6 - Lifecycle policy
# Automatically moves old data to cheaper storage after 90 days
# Deletes old versions after 365 days to save costs
resource "aws_s3_bucket_lifecycle_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id

  rule {
    id     = "lifecycle-rule"
    status = "Enabled"
    transition {
      # After 90 days move to STANDARD_IA - cheaper storage for infrequently accessed data
      days          = 90
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration {
      # Delete old versions after 365 days
      noncurrent_days = 365
    }
  }
}

# FIX 7 - Event notifications
# Sends an alert to an SNS topic whenever something happens in the bucket
# SNS is Simple Notification Service - AWS's alerting system
resource "aws_s3_bucket_notification" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  topic {
    # The SNS topic that receives the notifications
    topic_arn = aws_sns_topic.bucket_notifications.arn
    # Alert on any event - creates, deletes, restores
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }
}

# The SNS topic that receives bucket event notifications
resource "aws_sns_topic" "bucket_notifications" {
  name = "s3-bucket-notifications"
}