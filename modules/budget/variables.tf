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
  description = "List of unique absolute dollar amounts that trigger alert emails"
  type        = list(number)
  default     = [0.01, 1, 2, 3, 4, 5]

  validation {
    condition     = length(var.alert_thresholds) == length(distinct(var.alert_thresholds))
    error_message = "alert_thresholds must not contain duplicate values."
  }

  validation {
    condition     = alltrue([for t in var.alert_thresholds : t > 0])
    error_message = "All alert_thresholds must be positive numbers."
  }
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}
