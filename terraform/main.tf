# This tells Terraform we are using AWS and sets the region
provider "aws" {
  region = "us-east-1"
}

# This creates an S3 bucket - a storage container in AWS
# We are intentionally leaving encryption OFF so Checkov catches it
resource "aws_s3_bucket" "app_bucket" {
  bucket = "devsecops-pipeline-app-bucket"
}