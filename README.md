# AWS DevSecOps Pipeline

A security-gated CI/CD pipeline on AWS and GitHub Actions. Every commit passes through automated security gates, infrastructure is defined in Terraform, and deployments to Amazon EKS only happen through a manually approved, credential-free workflow. Controls are mapped to NIST 800-53.

---

## Scenario

A mid-sized SaaS company wants to sell to federal agencies, which requires **FedRAMP authorization**. As part of that effort, it is migrating its applications from manually managed servers to containers on Amazon EKS. A readiness assessment against **NIST 800-53** found gaps at every step of the release process:

- **Secrets:** AWS access keys stored in repositories and CI tools
- **Infrastructure:** cloud resources created by hand, with inconsistent encryption and some publicly exposed
- **Code and dependencies:** no scanning of application code or third-party libraries, and no inventory of what is inside the containers
- **Running application:** no testing of the live application for web vulnerabilities
- **Deployments:** anyone with access could push to production, with no approval or audit trail
- **Operations:** limited logging and no visibility into cluster health

This pipeline closes each gap and produces the evidence an assessor needs.

| Gap | Solution | NIST 800-53 |
|---|---|---|
| Keys in repositories | Gitleaks secret scanning, OIDC with no stored credentials | IA-5 |
| Hand-built, misconfigured infrastructure | Terraform, Checkov IaC scanning | CM-2, CM-6 |
| Unscanned code and dependencies | SonarCloud SAST, Syft SBOM, Grype CVE scanning | RA-5, SA-11, CM-8 |
| Untested running application | OWASP ZAP DAST | SA-11 |
| Uncontrolled deployments | Manual approval gate, immutable image tags | CM-3 |
| Exposed or unencrypted resources | Private EKS endpoint, KMS encryption, IRSA | SC-7, SC-28, AC-6 |
| No logging or visibility | VPC Flow Logs, EKS control plane logs, Prometheus/Grafana | AU-2, AU-11, SI-4 |

---

## Architecture

**Every commit — security gates (no cloud resources, no cost):**

```
Gitleaks → Checkov → SonarCloud → OWASP ZAP → Syft/Grype
 secrets     IaC        SAST         DAST       SBOM + CVE
```

**Manual deploy — `workflow_dispatch` only:**

```
Terraform Provision → Build & Push to ECR → Kubernetes Deploy → Prometheus/Grafana
```

Each job depends on the one before it. A failed gate stops everything downstream. Infrastructure changes never run automatically on a push; they require a deliberate, manually triggered deploy.

---

## Pipeline

### Security gates (every commit)

**Secret Scan — Gitleaks**
Scans the full Git history, not just the latest commit, for hardcoded credentials, tokens, and keys.
*Why first:* a leaked secret is exposed the moment it is pushed, so nothing else should run until history is clean.

**IaC Scan — Checkov**
Scans Terraform code for misconfigurations such as public access, missing encryption, over-broad IAM, and disabled logging.
*Why before Terraform:* Checkov reads code, not live infrastructure. Misconfigurations are caught before they exist in AWS.

**SAST — SonarCloud**
Static analysis of application source code for injection flaws, insecure functions, and code-quality issues.

**DAST — OWASP ZAP**
Starts the application in an ephemeral container on the runner and scans it from the outside for missing security headers, cookie flaws, and common web vulnerabilities. The HTML report is saved as a pipeline artifact.
*Design note:* this is a pre-deploy scan that gates the release. In production, a second post-deploy scan against staging would test the real network path.

**SBOM and CVE Scan — Syft and Grype**
Syft generates a Software Bill of Materials in SPDX format listing every package in the image. Grype scans it and fails the build on fixable critical CVEs. Unfixable CVEs remain documented in the SBOM, which is stored as an artifact.

### Deployment (manual only)

**Terraform Provision**
Provisions the VPC, subnets, NAT Gateway, KMS, ECR, EKS, IAM, IRSA, GuardDuty, S3, and logging. The plan is saved and the exact reviewed plan is applied.
*Why before build and push:* Terraform creates the ECR repository the image is pushed to.

**Build and Push to ECR**
Authenticates to AWS with OIDC, builds the image, tags it with the Git commit SHA, pushes it to ECR, and verifies the pushed tag exists.

**Kubernetes Deploy**
Deploys the exact image built from the commit to EKS and waits for a successful rollout.

**Monitoring**
Installs Prometheus and Grafana with the `kube-prometheus-stack` Helm chart.

---

## AWS Infrastructure

| Component | Configuration |
|---|---|
| VPC | Public and private subnets across 2 pinned Availability Zones |
| Default security group | All rules removed (deny-all) |
| NAT Gateway | Outbound-only internet access for private subnets |
| EKS | Private API endpoint, KMS envelope encryption for Secrets, all 5 control plane log types |
| EKS node group | Managed nodes in private subnets only |
| IRSA | Per-pod IAM roles via OIDC instead of shared node credentials |
| ECR | Immutable tags, scan on push, KMS encryption |
| KMS | Customer-managed key with automatic rotation |
| VPC Flow Logs | All traffic to CloudWatch, KMS-encrypted, 365-day retention |
| GuardDuty | EKS runtime monitoring enabled |
| S3 | KMS encryption, versioning, public access blocked, lifecycle rules |
| Terraform state | Remote S3 backend, encrypted, with state locking |
| GitHub to AWS | OIDC federation with short-lived credentials |

---

## Security Audit

The pipeline was originally built with AI assistance, then audited line by line against NIST 800-53. The audit found real issues:

| Finding | Risk | Fix | NIST |
|---|---|---|---|
| EKS API endpoint publicly accessible, contradicting its own code comment | Control plane exposed to the internet | Endpoint set to private only | SC-7, AC-17 |
| ECR tags mutable | A scanned image could be silently replaced | Tags set to immutable | CM-3 |
| Terraform state stored only locally | No locking, no backup, no audit trail | Encrypted S3 backend with locking | CM-3 |
| Deploy stage ran before the Terraform stage that creates ECR | Pipeline fails on a fresh environment | Reordered: Terraform before build and push | CM-3 |
| Infrastructure deployed automatically on every push | Unreviewed changes reach AWS | Deploy jobs gated behind manual trigger | CM-3 |
| No secret scanning | Leaked credentials go undetected | Gitleaks added as the first gate | IA-5 |
| ZAP scan erroring while the job reported success | DAST gate silently not running | Fixed report volume and permissions | SA-11 |
| Pipeline permissions broader than needed | Excess token scope | Reduced to `contents: read`, `id-token: write` | AC-6 |
| Third-party actions referenced by `@master` | Unreviewed upstream changes run in the pipeline | Pinned to versioned releases | SA-12 |

---

## Scan Results

**Gitleaks:** full Git history scanned, no secrets found.

**Checkov:** 14 findings — **10 remediated, 4 risk-accepted**.

| Remediated | NIST |
|---|---|
| Public subnets no longer auto-assign public IPs | SC-7 |
| Default security group locked to deny-all | SC-7 |
| All 5 EKS control plane log types enabled | AU-2, AU-12 |
| Flow log retention increased from 30 to 365 days | AU-11 |
| Flow log group encrypted with KMS | SC-28 |
| Flow log IAM policy scoped from `*` to its own log group | AC-6 |
| S3 lifecycle rules for old versions and incomplete uploads | SI-12 |
| Availability Zones pinned instead of looked up dynamically | CM-2 |

| Risk-accepted | Justification |
|---|---|
| S3 cross-region replication | Single-region demo; DR replication documented as a production gap |
| S3 event notifications | No downstream consumer for bucket events |
| S3 access logging | API activity audited via CloudTrail; a log bucket would cascade the same findings |
| GuardDuty organization configuration | Single-account environment without AWS Organizations |

Risk acceptances are documented inline with `checkov:skip` justifications, the code-level equivalent of POA&M entries.

**OWASP ZAP:** **5 warnings → 1**, 0 failures. Missing HTTP security headers were added through a Flask `after_request` hook so every response, including error pages, is covered. The remaining informational finding confirms responses are non-cacheable, which is intended.

**Grype:** fixable CVEs in `gunicorn`, `flask`, `pip`, and `wheel` were patched by upgrading dependencies. The pipeline fails on fixable critical CVEs; unfixable OS-level findings remain recorded in the SBOM.

---

## Troubleshooting Log

| Problem | Root cause | Resolution |
|---|---|---|
| Checkov failed on log bucket and SNS configuration | Missing encryption, logging, and public access controls | Remediated findings; added justified skips where a rule did not apply |
| SonarCloud scan conflicted with SonarCloud | Automatic analysis and CI analysis both enabled | Disabled automatic analysis and ran SAST through the pipeline |
| ZAP report upload failed | Action artifact naming bug and missing permissions | Ran ZAP directly as a container |
| Grype failed the build | Fixable CVEs in Python dependencies | Upgraded dependencies; scoped the gate to fixable criticals |
| ECR push failed | OIDC trust and IAM permissions misconfigured | Corrected the role trust policy and `id-token: write` permission |
| SAST failed months later | SonarCloud token expired | Rotated the token and migrated to `sonarqube-scan-action` |
| Checkov failed with new findings months later | Code drift and newer Checkov policies | Triaged 14 findings: 10 fixed, 4 risk-accepted |
| ZAP job green but scan not completing | `continue-on-error` masked ZAP exit code 3; report path not writable by the ZAP user | Mounted a writable output folder and uploaded the report as an artifact |
| Merge conflict in `main.tf` during rebase | Local and remote versions both modified the ECR block | Resolved manually, keeping the hardened configuration |

---

## Key Decisions

**Why OIDC instead of IAM access keys?**
Long-lived keys are a leading cause of cloud breaches. OIDC issues short-lived credentials per pipeline run, so nothing is stored in GitHub.

**Why immutable ECR tags?**
A mutable tag can be overwritten, breaking the link between what was scanned and what runs. Immutable tags guarantee that link.

**Why tag images with the commit SHA?**
Every running image traces back to the exact code that built it.

**Why a customer-managed KMS key?**
It allows explicit control over who can decrypt Kubernetes secrets, image layers, logs, and state.

**Why IRSA instead of node roles?**
A node role gives every pod on that node the same permissions. IRSA gives each pod only what its workload needs.

**Why a private EKS endpoint?**
It removes the Kubernetes control plane from the public internet. The tradeoff: administration and deployment require network access to the VPC, such as a bastion, VPN, or self-hosted runner.

**Why gate deployments behind a manual trigger?**
Security scans should run on every change. Infrastructure changes should be deliberate and reviewed.

**Why Checkov before Terraform?**
Scanning code catches misconfigurations before they exist, which is cheaper and safer than finding them in a live environment.

**Why drop all Linux capabilities in pods?**
Even if a process is compromised, it cannot alter networking, mount filesystems, or make privileged kernel calls.

---

## Tools

| Layer | Tools |
|---|---|
| Pipeline | GitHub Actions, OIDC |
| Secret scanning | Gitleaks |
| Static analysis | Checkov (IaC), SonarCloud (SAST) |
| Dynamic analysis | OWASP ZAP |
| Supply chain | Syft (SBOM), Grype (CVE) |
| Infrastructure | Terraform, AWS VPC, EKS, ECR, KMS, IAM, GuardDuty, S3 |
| Containers | Docker, Kubernetes, Helm |
| Observability | CloudWatch, Prometheus, Grafana |

---

## Production Readiness Gaps

| Gap | What production would add |
|---|---|
| Single environment | Separate dev, staging, and production state and accounts |
| Deploy from GitHub-hosted runners | Self-hosted runner inside the VPC for the private EKS endpoint |
| Single NAT Gateway | One NAT Gateway per Availability Zone |
| No ingress or TLS | AWS Load Balancer Controller, ACM certificates, WAF |
| Single-region S3 | Cross-region replication and a tested DR runbook |
| Pre-deploy DAST only | Additional post-deploy scan against staging |
| Personal SonarCloud token | Organization-scoped token not tied to an individual |
| Metrics only | Alerting rules, SLOs, and log aggregation |

---

## Running It

**Prerequisites:** an AWS account, a GitHub repository with Actions enabled, a SonarCloud project, an S3 bucket for Terraform state, and an IAM role trusted for GitHub OIDC.

**GitHub secrets:**

| Secret | Purpose |
|---|---|
| `AWS_ROLE_ARN` | IAM role assumed through OIDC |
| `AWS_REGION` | Target region |
| `SONAR_TOKEN` | SonarCloud authentication |

**Security gates:** push to `main`.

**Deploy:** Actions → DevSecOps Pipeline → **Run workflow**.

**Teardown:**

```bash
cd terraform
terraform destroy
```

The full stack was provisioned and deployed, then torn down to avoid ongoing cost. Security gates continue to run on every commit.
