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
