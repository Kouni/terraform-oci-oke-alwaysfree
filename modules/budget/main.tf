resource "oci_budget_budget" "this" {
  compartment_id = var.compartment_ocid
  amount         = var.budget_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.compartment_ocid]
  display_name   = "alwaysfree-budget"
  description    = "Always Free safety net — alerts when any actual spend is detected"
  freeform_tags  = var.freeform_tags
}

resource "oci_budget_alert_rule" "this" {
  for_each = { for t in var.alert_thresholds : format("%.2f", t) => t }

  budget_id      = oci_budget_budget.this.id
  type           = "ACTUAL"
  threshold      = each.value
  threshold_type = "ABSOLUTE"
  recipients     = var.notification_email
  display_name   = "alert-at-${each.key}-usd"
  description    = "Alert when actual spend reaches ${"$"}${each.key}"
  message        = "WARNING: Your OCI Always Free account has spent ${"$"}${each.key}. Please check the OCI Console immediately."
  freeform_tags  = var.freeform_tags
}
