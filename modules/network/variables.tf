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
