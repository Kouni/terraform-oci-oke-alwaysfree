locals {
  # vcn_cidr is fixed because subnet CIDRs (10.0.0.0/28, 10.0.1.0/24, 10.0.2.0/24)
  # are hardcoded within this range. Do not parameterize.
  vcn_cidr = "10.0.0.0/16"

  api_endpoint_subnet_cidr = "10.0.0.0/28"
  worker_subnet_cidr       = "10.0.1.0/24"
  lb_subnet_cidr           = "10.0.2.0/24"
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
