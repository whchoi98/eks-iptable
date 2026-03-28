---
name: code-review
description: Review shell scripts and K8s manifests for correctness, security, and best practices
---

Review the specified files for:

1. **Shell scripts**: shellcheck issues, error handling, quoting, set -e usage
2. **K8s manifests**: resource limits, security context, label consistency
3. **eksctl configs**: version compatibility, addon versions, VPC/subnet references
4. **Helm values**: storageClass, resource requests/limits, scrape configs

Output issues as a numbered list with severity (HIGH/MEDIUM/LOW) and file:line references.
