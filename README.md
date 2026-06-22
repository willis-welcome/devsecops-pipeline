# AWS DevSecOps Security Pipeline

A security-gated 8-stage deployment pipeline built on AWS.

## What this does
Stops insecure code and infrastructure from reaching production.
Every stage is a checkpoint. If any checkpoint fails, nothing deploys.

## Stages
1. Checkov IaC Security Scan
2. SonarQube SAST
3. OWASP ZAP DAST
4. Syft SBOM Generation and Grype CVE Scan
5. Docker Build and Push to ECR
6. Terraform Provisions EKS
7. Kubernetes Hardened Deployment
8. Prometheus and Grafana via Helm

## Tools
GitHub Actions, OIDC, Terraform, AWS EKS, Checkov, SonarQube,
OWASP ZAP, Syft, Grype, Docker, ECR, Helm, Prometheus, Grafana