# ─── GUARDDUTY ─────────────────────────────────────────────────
resource "aws_guardduty_detector" "main" {
  # checkov:skip=CKV2_AWS_3:Single-account environment; org-level GuardDuty requires AWS Organizations
  enable = true
}

resource "aws_guardduty_detector_feature" "eks_runtime" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"
}

