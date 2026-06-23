# AWS DevSecOps Security Pipeline

A production-grade, security-gated 8-stage CI/CD pipeline built on AWS and GitHub Actions. Every code change automatically passes through security checkpoints before anything reaches production. If any checkpoint fails, the pipeline stops and nothing deploys.

## Business Problem This Solves

Traditional deployment workflows allow developers to push code directly to production without automated security validation. Security reviews happen manually, infrequently, and after the fact. Vulnerabilities reach production. Compliance findings surface during audits instead of during development. Remediation costs 100x more than catching issues at the code stage.

This pipeline enforces security automatically on every single commit. No manual steps. No human error. No way to skip the gates.

## Architecture Overview
GitHub Push → Checkov → SonarCloud → OWASP ZAP → Grype → Docker/ECR → Terraform/EKS → K8s Deploy → Prometheus/Grafana

Every stage must pass before the next one starts. One failure stops everything downstream.

## AWS Infrastructure

- **VPC** with public and private subnets across 2 availability zones
- **NAT Gateway** — private subnets have outbound-only internet access
- **EKS Cluster** — Kubernetes 1.32 with KMS encryption for secrets at rest
- **IRSA** — each pod gets its own IAM role, no shared node credentials
- **GuardDuty** — runtime threat detection on EKS workloads
- **VPC Flow Logs** — full network audit trail to CloudWatch
- **ECR** — private container registry with immutable tags and scan-on-push
- **KMS** — customer managed encryption keys with automatic annual rotation
- **OIDC** — GitHub Actions authenticates to AWS without storing any credentials

## Pipeline Stages

### Stage 1 — Checkov IaC Security Scan
Scans all Terraform files before any infrastructure is provisioned. Catches misconfigurations at the blueprint stage — open security groups, missing encryption, disabled logging, absent public access blocks. Identified and remediated 9 security findings including missing KMS encryption, absent public access blocks, disabled versioning, and missing lifecycle policies.

**Security concept:** Shift-left — find infrastructure problems before they exist in AWS where they cost nothing to fix.

### Stage 2 — SonarCloud SAST
Static Application Security Testing. Reads application source code without executing it and identifies security vulnerability patterns — injection flaws, hardcoded credentials, insecure functions, sensitive data exposure.

**Security concept:** Static analysis catches what code review misses because it never gets tired and knows every known vulnerability pattern.

### Stage 3 — OWASP ZAP DAST
Dynamic Application Security Testing. Spins up the application in an isolated environment and attacks it from the outside — probing every endpoint, attempting injection attacks, checking security headers and cookie flags.

**Security concept:** Runtime vulnerabilities are invisible in source code. DAST finds what SAST cannot by actually running and attacking the application.

### Stage 4 — Syft SBOM + Grype CVE Scan
Syft generates a Software Bill of Materials — a complete ingredient list of every library and dependency inside the container image. Grype checks every item against CVE databases and fails the pipeline on any critical vulnerability with an available fix.

**Security concept:** Supply chain security. Log4Shell affected millions of applications whose developers had no idea Log4j was even a dependency. This stage catches that automatically on every build.

### Stage 5 — Docker Build and Push to ECR
Packages the application into a container image tagged with the Git commit SHA and pushes it to ECR with immutable tagging enabled. Authentication uses OIDC — no credentials stored anywhere. Temporary tokens issued per pipeline run and expired automatically.

**Security concept:** Immutable artifacts — the exact image that passed all security scans is the exact image that deploys. Nothing in between can tamper with it.

### Stage 6 — Terraform Provisions EKS Infrastructure
Builds the complete AWS environment as code — VPC, subnets, NAT Gateway, EKS cluster with KMS secret encryption, IRSA, GuardDuty, VPC Flow Logs, and CloudWatch logging. Infrastructure is version controlled, reviewable, and auditable.

**Security concept:** Infrastructure as Code means every security setting is documented in a file, not hidden in a console click.

### Stage 7 — Kubernetes Hardened Deployment
Deploys the container to EKS with defense-in-depth security controls at the pod level:
- `runAsNonRoot: true` — cannot run as administrator
- `readOnlyRootFilesystem: true` — cannot write files, blocking malware persistence
- `allowPrivilegeEscalation: false` — cannot gain elevated permissions
- `capabilities: drop: ALL` — no privileged Linux system calls
- Resource limits — cannot consume the node if compromised
- IRSA service account — pod-level AWS credentials, not node-level

**Security concept:** Defense in depth at the container level. Assumes an attacker may get code execution and removes every weapon they could use.

### Stage 8 — Prometheus and Grafana via Helm
Deploys a full observability stack to the cluster using Helm. Prometheus scrapes metrics every 15 seconds — CPU, memory, request rates, error rates. Grafana visualizes everything on pre-built Kubernetes dashboards.

**Security concept:** You cannot defend what you cannot see. Observability detects anomalies that indicate active attacks — unexpected CPU spikes, error rate changes, unusual network patterns.

## Security Findings Remediated

| Tool | Findings | Examples |
|------|----------|---------|
| Checkov | 9 | Missing KMS encryption, no public access block, versioning disabled, no lifecycle policy, missing key policy |
| SonarCloud | 4 | No HTTPS-only bucket policy, missing access logging, insecure action references |
| Grype | 12+ | gunicorn CVE, flask CVE, pip CVE, wheel CVE — all patched by updating to fixed versions |

## Tools Used

| Tool | Purpose |
|------|---------|
| GitHub Actions | Pipeline orchestration |
| OIDC | Passwordless AWS authentication |
| Terraform | Infrastructure as Code |
| Checkov | IaC security scanning |
| SonarCloud | Static application security testing |
| OWASP ZAP | Dynamic application security testing |
| Syft | SBOM generation |
| Grype | CVE scanning |
| Docker | Container packaging |
| ECR | Private container registry |
| EKS | Managed Kubernetes |
| IRSA | Pod-level IAM |
| KMS | Encryption key management |
| GuardDuty | Runtime threat detection |
| Helm | Kubernetes package management |
| Prometheus | Metrics collection |
| Grafana | Metrics visualization |

## How to Run

### Prerequisites
- AWS account with appropriate permissions
- GitHub repository with Actions enabled
- SonarCloud account connected to repository

### GitHub Secrets Required
- `AWS_ROLE_ARN` — IAM role ARN for OIDC authentication
- `AWS_REGION` — AWS region
- `SONAR_TOKEN` — SonarCloud authentication token

### Deploy
Push any change to the `main` branch. The pipeline triggers automatically and runs all 8 stages in sequence.

### Destroy Infrastructure
```bash
cd terraform
terraform destroy -auto-approve
```

## Key Security Decisions

**Why OIDC instead of access keys?** Access keys are static credentials that can be stolen, accidentally committed, or forgotten in rotation. OIDC issues temporary credentials per pipeline run that expire automatically. Nothing to steal, nothing to rotate.

**Why immutable ECR tags?** Mutable tags allow silent image replacement. An attacker with registry access could swap a trusted image for a malicious one under the same tag. Immutable tags make that impossible.

**Why KMS over AES256?** AES256 uses AWS-managed keys. KMS uses customer-managed keys — you control who can use them, you can rotate them, and every use is logged in CloudTrail. Required for FedRAMP High and NIST 800-53 compliance.

**Why IRSA over node IAM roles?** Node IAM roles give every pod on a node the same AWS permissions. If one pod is compromised every pod's permissions are exposed. IRSA gives each pod its own role with only the permissions it needs.

**Why drop ALL Linux capabilities?** Linux capabilities are fine-grained root permissions. An attacker with code execution inside a container cannot escalate privileges, modify network settings, or perform privileged system calls if all capabilities are dropped.

## This Project Is Independent Work

This pipeline was built independently to demonstrate Cloud Security Engineering and DevSecOps capabilities. It is not connected to any client or employer work.