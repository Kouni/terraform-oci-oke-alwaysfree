variable "compartment_ocid" {
  description = "The tenancy root OCID (budgets must target root compartment)"
  type        = string
}

variable "notification_email" {
  description = "Email address to receive budget alert notifications"
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget amount in USD"
  type        = number
  default     = 1
}

variable "alert_thresholds" {
  description = "List of absolute dollar amounts that trigger alert emails"
  type        = list(number)
  default     = [0.01, 1, 2, 3, 4, 5]
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}
