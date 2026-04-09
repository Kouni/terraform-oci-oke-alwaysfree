# Fetch OCI services CIDR for Service Gateway
data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

locals {
  all_services_id   = data.oci_core_services.all.services[0].id
  all_services_cidr = data.oci_core_services.all.services[0].cidr_block

  api_endpoint_subnet_cidr = "10.0.0.0/28"
  worker_subnet_cidr       = "10.0.1.0/24"
  lb_subnet_cidr           = "10.0.2.0/24"
}

# ──────────────────────────────────────────────────────────────────────────────
# VCN
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
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

# Placeholder for future private-subnet migration. Currently no route table
# references this gateway because all subnets are public. When converting
# the worker subnet to private, add a route rule pointing 0.0.0.0/0 to
# this NAT Gateway and remove the IGW rule from the worker route table.
resource "oci_core_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "nat-gateway"

  freeform_tags = var.freeform_tags
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

  # NOTE: OCI does not allow IGW and SGW (All Services) in the same route table.
  # SGW routes are only valid in private subnets (no IGW). In this public-subnet
  # design, OCI service traffic egresses via IGW. The SGW exists for future
  # private-subnet migration; see the NAT Gateway comment above.

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

  # NOTE: OCI does not allow IGW and SGW (All Services) in the same route table.
  # SGW routes are only valid in private subnets (no IGW). In this public-subnet
  # design, OCI service traffic egresses via IGW. The SGW exists for future
  # private-subnet migration; see the NAT Gateway comment above.

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

  # Allow Kubernetes API access from anywhere (secured by OKE auth)
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      min = 6443
      max = 6443
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

  # Allow API endpoint to reach OCI services
  egress_security_rules {
    protocol         = "6" # TCP
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"
    stateless        = false

    tcp_options {
      min = 443
      max = 443
    }
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

  # Allow ICMP path discovery from API endpoint
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
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

  # Allow worker to reach OCI services via Service Gateway
  egress_security_rules {
    protocol         = "6" # TCP
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"
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
