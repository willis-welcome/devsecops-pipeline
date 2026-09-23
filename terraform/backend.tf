# Stores Terraform state in encrypted S3 with locking instead of on a laptop
terraform {
  backend "s3" {
    bucket       = "willis-devsecops-tfstate"
    key          = "devsecops-pipeline/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}