output "vcn_id" {
  description = "The OCID of the VCN"
  value       = oci_core_vcn.this.id
}

output "api_endpoint_subnet_id" {
  description = "The OCID of the API endpoint subnet"
  value       = oci_core_subnet.api_endpoint.id
}

output "worker_subnet_id" {
  description = "The OCID of the worker subnet"
  value       = oci_core_subnet.worker.id
}

output "lb_subnet_id" {
  description = "The OCID of the load balancer subnet"
  value       = oci_core_subnet.lb.id
}

output "nat_gateway_public_ip" {
  description = "Reserved Public IP of the NAT Gateway (null if enable_nat_gateway = false). All worker node egress traffic appears to originate from this IP — use this as the stable Tailscale exit node IP."
  value       = one(oci_core_public_ip.nat_gw[*].ip_address)
}

# ── Outputs used by migration.tf (blue-green migration support) ──

output "worker_route_table_id" {
  description = "OCID of the worker subnet route table. Used by migration.tf to attach the migration subnet to the same NAT-aware route table."
  value       = oci_core_route_table.worker.id
}

output "worker_security_list_id" {
  description = "OCID of the worker security list. Used by migration.tf so the migration subnet inherits the same security rules."
  value       = oci_core_security_list.worker.id
}
