variable "compartment_ocid" {
  description = "The OCID of the compartment to create network resources in"
  type        = string
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "kube_api_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the Kubernetes API endpoint on TCP/6443. Defaults to 0.0.0.0/0 for backward compatibility; restrict to known operator/CI CIDRs in production"
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.kube_api_allowed_cidrs) > 0
    error_message = "kube_api_allowed_cidrs must contain at least one CIDR block."
  }
}

variable "migration_worker_cidr" {
  description = "TEMPORARY: extra worker subnet CIDR (e.g. 10.0.3.0/24) to add to security list rules during blue-green migration. Both api-endpoint and worker security lists are updated to allow this CIDR alongside the permanent worker CIDR. Set to null after migration is complete."
  type        = string
  default     = null
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Create a NAT Gateway with a Reserved Public IP so all worker node egress traffic
    uses a single, stable IP address. Required for Tailscale exit node to have a
    fixed outbound IP.

    When true:
    - A Reserved Public IP is allocated (free when attached; never released while the
      NAT Gateway exists).
    - A NAT Gateway is created and attached to that Reserved IP.
    - The worker subnet becomes private (prohibit_public_ip_on_vnic = true): worker
      nodes no longer receive individual public IPs.
    - Worker Route Table routes 0.0.0.0/0 through the NAT Gateway instead of the
      Internet Gateway.

    ⚠️  DESTRUCTIVE: changing this value forces replacement of the worker subnet,
    which terminates and recreates all worker nodes (~15 min downtime).
    Use targeted apply to create the NAT resources first (Phase A, non-disruptive),
    then run full apply during a maintenance window (Phase B):

      # Phase A — build NAT resources, no downtime
      terraform apply \
        -target=module.network.oci_core_public_ip.nat_gw \
        -target=module.network.oci_core_nat_gateway.this

      # Phase B — full apply, worker subnet + nodes recreated
      terraform apply
  EOT
  type        = bool
  default     = false
}
