variable "compartment_ocid" {
  description = "The OCID of the compartment to create network resources in"
  type        = string
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN. Must be 10.0.0.0/16 because subnet CIDRs (10.0.0.0/28, 10.0.1.0/24, 10.0.2.0/24) are fixed"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = var.vcn_cidr == "10.0.0.0/16"
    error_message = "vcn_cidr must be \"10.0.0.0/16\". Subnet CIDRs are hardcoded within this range."
  }
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway. WARNING: NAT Gateway is NOT Always Free and will incur charges"
  type        = bool
  default     = false
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}
