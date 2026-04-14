# Contributing to terraform-oci-oke-alwaysfree

Thank you for your interest in contributing! This document describes how to set up your development environment, run validations, and submit changes.

## Table of Contents

- [Development Environment](#development-environment)
- [Project Structure](#project-structure)
- [Making Changes](#making-changes)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Reporting Issues](#reporting-issues)
- [Code Style](#code-style)

---

## Development Environment

### Prerequisites

| Tool | Minimum Version | Notes |
|------|----------------|-------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.5.0 | Required for `terraform_data` resource |
| [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) | latest | Required for kubeconfig generation |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.29+ | For cluster interaction |

### OCI Account Setup

1. Create an [OCI Free Tier account](https://www.oracle.com/cloud/free/)
2. Configure the OCI CLI: `oci setup config`
3. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your values

### Local Validation (no OCI credentials required)

```bash
# Format check
terraform fmt -check -recursive

# Initialize providers (skips backend)
terraform init -backend=false

# Validate configuration
terraform validate
```

---

## Project Structure

```
.
├── main.tf                    # Root module: validation guard, cluster add-ons, app deployments
├── variables.tf               # All input variables with validation rules
├── outputs.tf                 # Root outputs
├── versions.tf                # Provider and Terraform version constraints
├── terraform.tfvars.example   # Example variable values
├── modules/
│   ├── network/               # VCN, subnets, gateways, security lists
│   ├── oke/                   # OKE cluster and node pool
│   └── budget/                # OCI monthly budget and alerts
├── k8s/                       # Kubernetes manifests and deployment guides
├── docs/                      # Architecture decisions and guides
├── scripts/                   # Backup and restore scripts
└── charts/                    # Vendored Helm charts (nfs-server-provisioner)
```

---

## Making Changes

### Branch Naming

All development must use a feature branch. Branch names follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) prefixes:

```
feat/short-description
fix/short-description
docs/short-description
chore/short-description
refactor/short-description
```

**Never commit directly to `main`.**

### Development Workflow

```bash
# 1. Create a branch
git checkout -b feat/your-feature

# 2. Make your changes

# 3. Format all Terraform files
terraform fmt -recursive

# 4. Validate the configuration
terraform init -backend=false
terraform validate

# 5. Commit with Conventional Commits message
git commit -m "feat(network): add optional NAT gateway toggle"
```

### Testing Changes

This project manages real OCI infrastructure. For changes that affect resources:

1. Run `terraform plan` against a dedicated test compartment — **never against a production compartment**
2. Verify the plan shows only expected changes
3. Check the `terraform_data.always_free_validation` preconditions pass

For documentation-only changes, validation (`fmt -check` + `validate`) is sufficient.

---

## Submitting a Pull Request

1. Ensure `terraform fmt -check -recursive` passes
2. Ensure `terraform validate` passes (with `terraform init -backend=false`)
3. Update `terraform.tfvars.example` if you added new variables
4. Update `README.md` variables table if you added or changed variables
5. Open a PR against `main` — the CI workflow will run automatically

### Commit Message Format

Follow [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<scope>): <description>

[optional body]
```

**Types:** `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`, `ci`, `test`, `build`, `style`

**Scopes (optional):** `network`, `oke`, `budget`, `nfs`, `k8s`, `ci`

Examples:
- `feat(oke): add support for custom boot volume size validation`
- `fix(network): correct service gateway route rule for object storage`
- `docs: add architecture decision for Cloudflare Tunnel`
- `chore: update OCI provider version constraint`

---

## Reporting Issues

When opening an issue, please use the appropriate template:

- **Bug Report** — for unexpected behavior or errors
- **Feature Request** — for new functionality or improvements

Include as much context as possible: OCI region, Terraform version, relevant variable values (redact sensitive data), and the full error output.

---

## Code Style

- **Resource naming:** Single-instance resources within a module use `this` as the resource name (e.g., `oci_core_vcn.this`)
- **Optional resources:** Use `count = var.enable_x ? 1 : 0` pattern
- **Tagging:** Every resource must include `freeform_tags = var.freeform_tags`
- **Section separators:** Use `# ──────────────── Title ────────────────` to separate logical groups in long files
- **Hardcoded constraints:** Do not make Always Free safety constraints configurable (shape, cluster type, subnet CIDRs)
- **Sensitive variables:** Mark any secret or credential variable with `sensitive = true`
