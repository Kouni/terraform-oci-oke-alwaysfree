variable "compartment_ocid" {
  description = "The OCID of the compartment to create network resources in"
  type        = string
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}
