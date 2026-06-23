data "cloudflare_ip_ranges" "cloudflare" {}

resource "oci_core_network_security_group" "nebus_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.nebus_vcn.id
  display_name   = "nebus-nodes-nsg"
}

# Allow all traffic within the VCN for node-to-node communication (etcd, Flannel/Cilium, etc)
resource "oci_core_network_security_group_security_rule" "internal_ingress" {
  network_security_group_id = oci_core_network_security_group.nebus_nsg.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_vcn.nebus_vcn.cidr_block
  source_type               = "CIDR_BLOCK"
}

# Allow all egress traffic outside the cluster
resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.nebus_nsg.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# Process Cloudflare IPv4 ranges and map them to HTTP(80) and HTTPS(443) ports
locals {
  cf_ipv4 = data.cloudflare_ip_ranges.cloudflare.ipv4_cidr_blocks
  ports   = [80, 443]

  cf_rules_ipv4 = flatten([
    for ip in local.cf_ipv4 : [
      for port in local.ports : {
        ip   = ip
        port = port
      }
    ]
  ])
}

# Generate an NSG rule for each permutation of CF IP and port 
# (Excludes IPv6 to strictly remain compatible with standard single-stack OCI VCNs)
resource "oci_core_network_security_group_security_rule" "cf_ingress_ipv4" {
  count                     = length(local.cf_rules_ipv4)
  network_security_group_id = oci_core_network_security_group.nebus_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = local.cf_rules_ipv4[count.index].ip
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      max = local.cf_rules_ipv4[count.index].port
      min = local.cf_rules_ipv4[count.index].port
    }
  }
}
