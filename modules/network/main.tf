# Resolve the regional "All Services" bundle for use in security list rules and
# the Service Gateway. This data source is evaluated at plan time and does not
# create any resource.
data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

locals {
  # vcn_cidr is fixed because subnet CIDRs (10.0.0.0/28, 10.0.1.0/24, 10.0.2.0/24)
  # are hardcoded within this range. Do not parameterize.
  vcn_cidr = "10.0.0.0/16"

  api_endpoint_subnet_cidr = "10.0.0.0/28"
  worker_subnet_cidr       = "10.0.1.0/24"
  lb_subnet_cidr           = "10.0.2.0/24"

  all_services_cidr = data.oci_core_services.all.services[0].cidr_block
  all_services_id   = data.oci_core_services.all.services[0].id
}

# ──────────────────────────────────────────────────────────────────────────────
# VCN
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [local.vcn_cidr]
  display_name   = "oke-vcn"
  dns_label      = "okevcn"

  freeform_tags = var.freeform_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Gateways
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "internet-gateway"
  enabled        = true

  freeform_tags = var.freeform_tags
}

# Service Gateway allows OCI-internal traffic (CCM, CSI, OKE management) to
# reach Oracle Services Network without traversing the public internet.
# OCI prohibits mixing IGW and SGW routes in the same public-subnet route
# table, so no route rules reference this gateway — all subnets remain public
# and route via IGW. The SGW must exist in the VCN for SERVICE_CIDR_BLOCK to
# be valid as a security-list egress destination type (required by Oracle docs
# for OKE to function; see modules/network/main.tf api_endpoint egress rules).
resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "service-gateway"

  services {
    service_id = local.all_services_id
  }

  freeform_tags = var.freeform_tags

  lifecycle {
    precondition {
      condition     = length(data.oci_core_services.all.services) > 0
      error_message = "No OCI services found matching 'All * Services In Oracle Services Network'. Verify the OCI region supports Service Gateway."
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Route Tables
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_core_route_table" "api_endpoint" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "api-endpoint-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.this.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_route_table" "worker" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "worker-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.this.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_route_table" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "lb-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.this.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }

  freeform_tags = var.freeform_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Security Lists
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_core_security_list" "api_endpoint" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "api-endpoint-sl"

  # Allow Kubernetes API access from the configured CIDRs (authentication still enforced by OKE).
  # Defaults to 0.0.0.0/0 for backward compatibility; tighten via var.kube_api_allowed_cidrs.
  dynamic "ingress_security_rules" {
    for_each = toset(var.kube_api_allowed_cidrs)
    content {
      protocol    = "6" # TCP
      source      = ingress_security_rules.value
      source_type = "CIDR_BLOCK"
      stateless   = false

      tcp_options {
        min = 6443
        max = 6443
      }
    }
  }

  # Allow worker nodes to communicate with API endpoint
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = local.worker_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # Allow worker nodes to communicate with API endpoint (port 12250)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = local.worker_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 12250
      max = 12250
    }
  }

  # Allow ICMP path discovery from worker subnet
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = local.worker_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Allow API endpoint to communicate with worker nodes
  egress_security_rules {
    protocol         = "6" # TCP
    destination      = local.worker_subnet_cidr
    destination_type = "CIDR_BLOCK"
    stateless        = false
  }

  # Allow ICMP path discovery to worker subnet
  egress_security_rules {
    protocol         = "1" # ICMP
    destination      = local.worker_subnet_cidr
    destination_type = "CIDR_BLOCK"
    stateless        = false

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Required by Oracle: allow OKE control plane (VNIC in this subnet) to reach
  # Oracle Services Network for CCM topology labeling and CSI volume management.
  # Without this rule, the OKE migration service cannot call the OCI API and
  # every node boots with last-migration-failure=get_kubesvc_failure, blocking
  # all PVC provisioning. SERVICE_CIDR_BLOCK requires the Service Gateway to
  # exist in the VCN (see oci_core_service_gateway.this above).
  egress_security_rules {
    protocol         = "6" # TCP
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"
    stateless        = false
  }

  egress_security_rules {
    protocol         = "1" # ICMP
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"
    stateless        = false

    icmp_options {
      type = 3
      code = 4
    }
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_security_list" "worker" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "worker-sl"

  # Allow worker-to-worker communication (all ports, for pod networking)
  ingress_security_rules {
    protocol    = "all"
    source      = local.worker_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false
  }

  # Allow API endpoint to communicate with workers (kubelet)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = local.api_endpoint_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false
  }

  # Allow ICMP path discovery (PMTU) from within the VCN only.
  # Previously open to 0.0.0.0/0; narrowed to local.vcn_cidr to reduce reconnaissance surface.
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = local.vcn_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Allow LB health checks to NodePort range
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = local.lb_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 30000
      max = 32767
    }
  }

  # Allow LB to reach NodePort services (10256 for health check)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = local.lb_subnet_cidr
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 10256
      max = 10256
    }
  }

  # Allow all egress (for pulling images, cloudflared outbound, etc.)
  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    stateless        = false
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_security_list" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "lb-sl"

  # Allow inbound HTTPS
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 443
      max = 443
    }
  }

  # Allow inbound HTTP (for redirect to HTTPS)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 80
      max = 80
    }
  }

  # Allow LB to communicate with worker NodePorts
  egress_security_rules {
    protocol         = "6" # TCP
    destination      = local.worker_subnet_cidr
    destination_type = "CIDR_BLOCK"
    stateless        = false

    tcp_options {
      min = 30000
      max = 32767
    }
  }

  # Allow LB health checks to workers
  egress_security_rules {
    protocol         = "6" # TCP
    destination      = local.worker_subnet_cidr
    destination_type = "CIDR_BLOCK"
    stateless        = false

    tcp_options {
      min = 10256
      max = 10256
    }
  }

  freeform_tags = var.freeform_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Subnets
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_core_subnet" "api_endpoint" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.api_endpoint_subnet_cidr
  display_name               = "api-endpoint-subnet"
  dns_label                  = "apiendpoint"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.api_endpoint.id
  security_list_ids          = [oci_core_security_list.api_endpoint.id]

  freeform_tags = var.freeform_tags
}

resource "oci_core_subnet" "worker" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.worker_subnet_cidr
  display_name               = "worker-subnet"
  dns_label                  = "worker"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.worker.id
  security_list_ids          = [oci_core_security_list.worker.id]

  freeform_tags = var.freeform_tags
}

resource "oci_core_subnet" "lb" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.lb_subnet_cidr
  display_name               = "lb-subnet"
  dns_label                  = "lb"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.lb.id
  security_list_ids          = [oci_core_security_list.lb.id]

  freeform_tags = var.freeform_tags
}
