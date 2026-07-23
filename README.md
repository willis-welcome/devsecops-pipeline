# AWS DevSecOps Pipeline

A production-grade, security-gated 8-stage CI/CD pipeline built on AWS and GitHub Actions. Every code change automatically passes through security checkpoints before anything reaches production. If any checkpoint fails, the pipeline stops immediately, preventing insecure builds from reaching AWS.

---

## Business Problem This Solves

Traditional deployment workflows allow developers to push code directly to production without automated security validation. Security reviews often happen manually, infrequently, and after the fact. As a result:

* Vulnerabilities reach production undetected.
* Compliance findings surface during stressful audits instead of during development.
* Remediation costs up to **100x more** to fix post-deployment compared to catching issues at the code stage.

This pipeline enforces automated security gates on every single commit. **No manual steps. No human error. No way to bypass the gates.**

---

## Architecture & Flow Overview

GitHub Push → SonarCloud → Checkov → Terraform → Syft & Grype → Docker Push → K8s Deploy → OWASP ZAP → Prometheus/Grafana

> **Pipeline Rule:** Every stage must pass before the next one begins. A single tool failure halts the entire workflow downstream.

---

## AWS Infrastructure Provisioned

* **VPC & Subnets:** Isolated network with public and private subnets distributed across 2 Availability Zones for high availability.
* **NAT Gateway:** Ensures private subnet resources have outbound-only internet access while blocking direct incoming traffic.
* **ECR:** Private container registry with immutable image tags, scan-on-push enabled, and custom KMS encryption at rest.
* **EKS Cluster:** Kubernetes 1.32 control plane with KMS envelope encryption for Kubernetes Secrets.
* **IRSA (IAM Roles for Service Accounts):** Fine-grained, least-privilege AWS access assigned per Pod rather than using shared worker node credentials.
* **GuardDuty:** Continuous, 24/7 runtime threat detection monitoring EKS container workloads and API activity.
* **VPC Flow Logs:** Complete network access and traffic audit trail delivered directly to CloudWatch Logs with a 30-day retention policy.
* **KMS:** Customer Managed Keys (CMK) configured with automatic annual rotation controlling all data encryption.
* **OIDC:** Keyless authentication integration allowing GitHub Actions to assume temporary AWS IAM roles per pipeline run without storing long-lived static credentials.

---

## Pipeline Stages

### Stage 1 — SonarCloud (SAST)

* **What it does:** Performs Static Application Security Testing on application source code before execution. Detects injection flaws, insecure functions, hardcoded secrets, and OWASP Top 10 vulnerabilities.
* **Security Concept:** *Shift-Left Code Security.* Finds code-level flaws early when they are easiest and cheapest to remediate.

### Stage 2 — Checkov (IaC Scan)

* **What it does:** Scans all Terraform code (`.tf` files) prior to provisioning cloud infrastructure. Ensures blueprints adhere to security standards (e.g., public access blocks, KMS key policies, logging enabled).
* **Security Concept:** *Preventative Infrastructure Security.* Guarantees misconfigurations never reach the live cloud environment.

### Stage 3 — Terraform (Infra & ECR Provisioning)

* **What it does:** Provisions all required AWS infrastructure as code — VPC, KMS keys, ECR repository, EKS cluster, IRSA policies, GuardDuty, and CloudWatch log groups.
* **Security Concept:** *Declarative & Auditable Infrastructure.* Every cloud setting is explicitly defined, version-controlled, and peer-reviewed in Git.

### Stage 4 — Syft SBOM + Grype CVE Scan

* **What it does:** Syft generates a Software Bill of Materials (SBOM) listing every component, dependency, and base image layer. Grype scans this SBOM against vulnerability databases and breaks the build if critical unpatched CVEs are discovered.
* **Security Concept:** *Software Supply Chain Protection.* Automatically catches zero-days and third-party dependency vulnerabilities (like Log4Shell) prior to building release artifacts.

### Stage 5 — Docker Build & Push to ECR

* **What it does:** Builds the application container image, tags it with the Git commit SHA, and pushes it to AWS ECR via OIDC passwordless authentication.
* **Security Concept:** *Immutable & Authenticated Artifacts.* Uses short-lived AWS tokens. Image tags are immutable, ensuring the exact scanned image artifact is what reaches production.

### Stage 6 — Kubernetes Hardened Deployment

* **What it does:** Deploys the application image to EKS applying strict Pod Security Standards:
  * `runAsNonRoot: true` — Blocks execution as administrative root.
  * `readOnlyRootFilesystem: true` — Prevents runtime file modifications, neutering malware persistence.
  * `allowPrivilegeEscalation: false` — Blocks processes from gaining additional system rights.
  * `capabilities: drop: ["ALL"]` — Removes dangerous Linux kernel capabilities.
  * `Resource limits` — Prevents noisy neighbor issues or Denial of Service (DoS) from resource exhaustion.
* **Security Concept:** *Defense-in-Depth.* Operates on zero-trust assumptions inside the cluster, neutering exploit capabilities even if an attacker gains code execution.

### Stage 7 — OWASP ZAP (DAST)

* **What it does:** Executes Dynamic Application Security Testing against the live, running web application endpoint in EKS. Attacks the application externally, testing for cross-site scripting (XSS), SQL injection, missing HTTP security headers, and cookie flaws.
* **Security Concept:** *Black-box Runtime Validation.* Uncovers configuration and environment-specific security bugs that static code analysis cannot see.

### Stage 8 — Prometheus & Grafana Observability

* **What it does:** Deploys a full monitoring stack to the cluster via Helm. Prometheus scrapes container and cluster metrics every 15 seconds, driving Grafana visual dashboards for operational and security monitoring.
* **Security Concept:** *Continuous Security Observability.* Real-time metrics allow immediate identification of abnormal CPU/RAM spikes, elevated error rates, or suspicious traffic spikes that signal an ongoing attack.

---

## Security Findings Remediated

| Tool | Findings Cleared | Examples of Remediations Applied |
| --- | --- | --- |
| **Checkov** | **9** | Added KMS encryption to S3/ECR/EKS, enforced public access blocks, enabled bucket versioning, added missing KMS key policies. |
| **SonarCloud** | **4** | Applied HTTPS-only bucket policies, configured access logging, replaced insecure GitHub action references. |
| **Grype** | **12+** | Upgraded outdated Python base image dependencies patching severe CVEs in `gunicorn`, `flask`, `pip`, and `wheel`. |

---

## Tools & Security Stack Summary

| Security Layer | Tools Utilized |
| --- | --- |
| **Pipeline Automation** | GitHub Actions, OIDC Authentication |
| **Static Analysis** | SonarCloud (SAST), Checkov (IaC) |
| **Supply Chain / CVE** | Syft (SBOM), Grype (Vulnerability Scanner) |
| **Container & Infra** | Docker, AWS ECR, Terraform |
| **Orchestration** | AWS EKS, Helm |
| **Runtime Protection** | OWASP ZAP (DAST), AWS GuardDuty, IRSA |
| **Observability** | AWS CloudWatch, Prometheus, Grafana |

---

## How to Run

### Prerequisites

1. An active AWS Account with IAM permissions to manage VPC, EKS, KMS, and ECR.
2. A GitHub Repository with Actions enabled.
3. A SonarCloud Account connected to your repository.

### GitHub Secrets Required

| Secret Name | Description |
| --- | --- |
| `AWS_ROLE_ARN` | The IAM Role ARN configured for OIDC federation with GitHub Actions. |
| `AWS_REGION` | The targeted AWS region (e.g., `us-east-2`). |
| `SONAR_TOKEN` | Authentication token generated from SonarCloud. |

### Deployment

Push any change to the `main` branch. The pipeline triggers automatically and executes all 8 stages sequentially.

### Teardown Infrastructure

To avoid incurring unnecessary AWS costs, run:

\`\`\`bash
cd terraform
terraform destroy -auto-approve
\`\`\`

---

## Key Architectural & Security Decisions

> **Why OIDC over IAM Access Keys?**
> Long-lived access keys are one of the leading causes of cloud breaches due to accidental commits or poor rotation habits. OIDC uses short-lived tokens generated per job execution that expire automatically. There are zero credentials stored in GitHub Secrets.

> **Why Immutable ECR Tags?**
> Mutable tags allow an attacker or broken pipeline to overwrite an existing image tag (e.g., `:latest`). Tag immutability ensures that once an image SHA passes security gates, it can never be overwritten or tampered with.

> **Why KMS Customer-Managed Keys over Default Keys?**
> Default AWS keys don't allow key policy customization or cross-account management. Customer-managed KMS keys allow precise control over who can decrypt Kubernetes secrets or ECR layers, meeting FedRAMP High and NIST 800-53 compliance standards.

> **Why IRSA over Node-level IAM Roles?**
> Node IAM roles grant every pod on a worker node the permissions assigned to that underlying EC2 instance. IRSA scopes access to specific Kubernetes ServiceAccounts, granting each Pod only the exact AWS permissions required for its workload.

> **Why drop ALL Linux Capabilities in Kubernetes?**
> Linux capabilities break root privilege into distinct capabilities. Dropping `ALL` capabilities ensures that even if a process inside a container is compromised, the attacker cannot modify network routing, mount filesystems, or make privileged kernel system calls.

---

## Disclaimer

*This pipeline was built independently to demonstrate Cloud Security Engineering, Infrastructure as Code, and DevSecOps capabilities. It is not connected to or derived from any client or employer work.*
