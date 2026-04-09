variable "compartment_ocid" {
  description = "The OCID of the compartment to create OKE resources in"
  type        = string
}

variable "cluster_name" {
  description = "Display name for the OKE cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster. If null, uses the latest available version"
  type        = string
  default     = null
}

variable "vcn_id" {
  description = "The OCID of the VCN"
  type        = string
}

variable "api_endpoint_subnet_id" {
  description = "The OCID of the subnet for the Kubernetes API endpoint"
  type        = string
}

variable "worker_subnet_id" {
  description = "The OCID of the subnet for worker nodes"
  type        = string
}

variable "lb_subnet_id" {
  description = "The OCID of the subnet for load balancers"
  type        = string
}

variable "node_count" {
  description = "Number of worker nodes in the node pool"
  type        = number
  default     = 1
}

variable "node_ocpus" {
  description = "Number of OCPUs per worker node"
  type        = number
  default     = 4
}

variable "node_memory_in_gbs" {
  description = "Memory in GBs per worker node"
  type        = number
  default     = 24
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GBs per worker node"
  type        = number
  default     = 64
}

variable "ssh_public_key" {
  description = "SSH public key for worker node access. If null, SSH access is disabled"
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "always_free_validation_id" {
  description = "ID of the Always Free validation resource. Ensures cluster creation waits for validation without blocking data sources."
  type        = string
  default     = null
}
