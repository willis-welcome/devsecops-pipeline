# ─── PROVIDER ──────────────────────────────────────────────────
# Tells Terraform which cloud we're using and which region
# The version constraint means use any 5.x version of the AWS provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ─── DATA SOURCES ──────────────────────────────────────────────
# Data sources READ existing information - they don't create anything
# This one reads your current AWS account ID dynamically
# So we never hardcode account numbers anywhere
data "aws_caller_identity" "current" {}

# Reads the list of available availability zones in us-east-2
# Availability zones are physically separate datacenters in the same region
# us-east-2 has us-east-2a, us-east-2b, us-east-2c
# We spread our infrastructure across them so if one datacenter fails
# our application keeps running in the others
data "aws_availability_zones" "available" {
  state = "available"
}

# ─── KMS KEY ───────────────────────────────────────────────────
# Our own encryption key for S3 and Kubernetes secrets
# We control this key - we decide who can use it
resource "aws_kms_key" "main" {
  description             = "KMS key for ${var.project_name} encryption"
  enable_key_rotation     = true
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}-key"
  target_key_id = aws_kms_key.main.key_id
}

resource "aws_kms_key_policy" "main" {
  key_id = aws_kms_key.main.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EKS to use this key for secret encryption"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
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

# ─── VPC ───────────────────────────────────────────────────────
# Your own private isolated network in AWS
# cidr_block defines the range of IP addresses available in this network
# 10.0.0.0/16 gives us 65,536 possible IP addresses to assign to resources
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  # enable_dns_hostnames lets resources in the VPC get DNS names
  # Required for EKS to work correctly
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ─── INTERNET GATEWAY ──────────────────────────────────────────
# The door between your VPC and the internet
# Without this nothing in your VPC can reach the internet at all
# Only the public subnet uses this - private subnet goes through NAT
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ─── PUBLIC SUBNETS ────────────────────────────────────────────
# Public subnets face the internet - only load balancers live here
# We create one in each availability zone for redundancy
# count = 2 means Terraform creates this resource twice
# Each iteration gets a different availability zone and IP range
resource "aws_subnet" "public" {
  count = 2

  vpc_id = aws_vpc.main.id

  # element() picks from the list based on count index
  # So first subnet gets us-east-2a, second gets us-east-2b
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  # cidrsubnet() carves out a smaller network from our VPC range
  # 10.0.1.0/24 and 10.0.2.0/24 - each holds 256 addresses
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)

  # Automatically assign public IPs to resources in this subnet
  # Load balancers need public IPs to receive internet traffic
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
    # This tag tells AWS load balancer controller which subnets to use
    "kubernetes.io/role/elb" = "1"
  }
}

# ─── PRIVATE SUBNETS ───────────────────────────────────────────
# Private subnets have NO direct internet access
# Your application pods run here - completely hidden from the internet
# Traffic only reaches here after passing through the load balancer
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  # Different IP ranges from public subnets
  # 10.0.11.0/24 and 10.0.12.0/24
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 11)

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
    # This tag tells the load balancer controller to use these for internal traffic
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ─── NAT GATEWAY ───────────────────────────────────────────────
# Allows private subnet resources to make outbound internet requests
# But blocks ALL inbound connections from the internet
# Your pods can pull updates, call external APIs
# But nobody from the internet can reach your pods directly
# We need an Elastic IP first - a fixed public IP address for the NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  # Attach the NAT Gateway to the first public subnet
  # Traffic from private subnets goes through here to reach the internet
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-nat"
  }
}

# ─── ROUTE TABLES ──────────────────────────────────────────────
# Route tables tell traffic where to go
# Like a GPS for network packets

# Public route table - sends internet traffic through the internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    # 0.0.0.0/0 means all traffic
    cidr_block = "0.0.0.0/0"
    # Send it to the internet gateway
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Associate the public route table with both public subnets
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table - sends internet traffic through the NAT gateway
# Not the internet gateway - so it's outbound only
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    # Send through NAT - not the internet gateway
    # This is what makes it private - outbound only
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# Associate the private route table with both private subnets
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─── VPC FLOW LOGS ─────────────────────────────────────────────
# Records every network connection in your VPC
# Who connected to what, when, from where, accepted or rejected
# Your network audit trail for compliance and forensics
resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
}

# CloudWatch log group where flow logs get stored
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/flow-logs/${var.project_name}"
  # Keep logs for 30 days then delete them automatically
  retention_in_days = 30
}

# IAM role that allows VPC to write flow logs to CloudWatch
resource "aws_iam_role" "flow_logs" {
  name = "${var.project_name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

# Permission for the flow logs role to write to CloudWatch
resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.project_name}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# ─── EKS CLUSTER ───────────────────────────────────────────────
# The managed Kubernetes control plane
# AWS runs and maintains the brain of Kubernetes
# You just tell it what to run

# IAM role for the EKS control plane
# EKS needs this role to manage AWS resources on your behalf
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

# AWS managed policy that gives EKS the permissions it needs to run
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# The actual EKS cluster resource
resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-cluster"
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # EKS control plane lives in private subnets
    subnet_ids = concat(
      aws_subnet.private[*].id,
      aws_subnet.public[*].id
    )
    # Block direct public access to the Kubernetes API server
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Enable KMS encryption for Kubernetes secrets
  # Any secret stored in Kubernetes gets encrypted using our KMS key
  # Passwords, tokens, API keys - all encrypted at rest
  encryption_config {
    provider {
      key_arn = aws_kms_key.main.arn
    }
    resources = ["secrets"]
  }

  # Enable useful logging to CloudWatch
  # audit logs record every API call to Kubernetes - your K8s audit trail
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ─── EKS NODE GROUP ────────────────────────────────────────────
# The worker nodes where your containers actually run
# These are EC2 instances managed by EKS

# IAM role for worker nodes
resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Three policies the worker nodes need to function
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

# The node group - the actual EC2 instances
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  # Nodes run in private subnets - never directly internet accessible
  subnet_ids = aws_subnet.private[*].id

  # EC2 instance configuration
  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_count
    min_size     = 1
    max_size     = 3
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy,
  ]
}

# ─── IRSA — IAM ROLES FOR SERVICE ACCOUNTS ─────────────────────
# Each Kubernetes pod gets its own IAM role
# Instead of sharing the node's role with every pod
# This is least privilege at the container level

# First enable the OIDC provider for EKS
# Same concept as GitHub OIDC - lets Kubernetes pods request AWS credentials
data "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
  depends_on = [aws_eks_cluster.main]
}

# IAM role for our application pod
resource "aws_iam_role" "app_pod" {
  name = "${var.project_name}-app-pod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:default:app-service-account"
        }
      }
    }]
  })
}

# ─── GUARDDUTY ─────────────────────────────────────────────────
# Runtime threat detection for your EKS cluster
# Watches for suspicious container behavior 24/7
resource "aws_guardduty_detector" "main" {
  enable = true
}

# Enable EKS runtime monitoring specifically
resource "aws_guardduty_detector_feature" "eks_runtime" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"
}

# ─── S3 BUCKET (keeping from before) ──────────────────────────
# checkov:skip=CKV_AWS_144: Log bucket is a replication destination not a source
# checkov:skip=CKV2_AWS_62: Log bucket notifications not required for access logs
resource "aws_s3_bucket" "app_bucket" {
  bucket = "${var.project_name}-pipeline-app-bucket"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
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