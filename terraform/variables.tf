# Variables make our Terraform reusable and configurable
# Instead of hardcoding values everywhere we define them once here
# And reference them throughout our Terraform files

# The AWS region where everything gets built
variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-2"
}

# A name prefix we attach to every resource
# Makes it easy to find all resources for this project in the console
variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "devsecops"
}

# The Kubernetes version for our EKS cluster
# We pin this to a specific version so upgrades are controlled and deliberate
variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.32"
}

# The EC2 instance type for our worker nodes
# t3.medium gives us 2 vCPUs and 4GB RAM - enough for our demo workload
# In production you'd use larger instances
variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

# How many worker nodes to run
# 2 nodes means if one fails your app keeps running on the other
variable "node_count" {
  description = "Number of EKS worker nodes"
  type        = number
  default     = 2
}