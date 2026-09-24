variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "devsecops"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version, pinned so upgrades are deliberate"
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Desired number of EKS worker nodes"
  type        = number
  default     = 2
}

variable "availability_zones" {
  description = "Pinned AZs so the subnet layout never changes silently"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}
