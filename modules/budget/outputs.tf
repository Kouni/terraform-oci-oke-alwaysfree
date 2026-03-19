output "budget_id" {
  description = "The OCID of the budget"
  value       = oci_budget_budget.this.id
}

output "alert_rule_ids" {
  description = "The OCIDs of the budget alert rules"
  value       = { for k, v in oci_budget_alert_rule.this : k => v.id }
}
