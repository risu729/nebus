resource "oci_core_vcn" "nebus_vcn" {
  compartment_id = var.compartment_ocid
  display_name   = "nebus-vcn"
  cidr_block     = "10.0.0.0/16"
  dns_label      = "nebus"
}

resource "oci_core_internet_gateway" "nebus_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.nebus_vcn.id
  enabled        = true
  display_name   = "nebus-igw"
}

resource "oci_core_nat_gateway" "nebus_nat" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.nebus_vcn.id
  display_name   = "nebus-nat"
}

data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "nebus_sgw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.nebus_vcn.id
  display_name   = "nebus-sgw"

  services {
    service_id = data.oci_core_services.all_services.services[0].id
  }
}

# Public Route Table (For Load Balancers if provisioned later)
resource "oci_core_default_route_table" "nebus_public_rt" {
  manage_default_resource_id = oci_core_vcn.nebus_vcn.default_route_table_id

  route_rules {
    network_entity_id = oci_core_internet_gateway.nebus_igw.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

# Private Route Table (For Talos and Bastion)
resource "oci_core_route_table" "nebus_private_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.nebus_vcn.id
  display_name   = "nebus-private-rt"

  route_rules {
    network_entity_id = oci_core_nat_gateway.nebus_nat.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }

  route_rules {
    network_entity_id = oci_core_service_gateway.nebus_sgw.id
    destination       = data.oci_core_services.all_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
  }
}

# Private Subnet for Talos Nodes and Bastion
resource "oci_core_subnet" "nebus_private_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.nebus_vcn.id
  cidr_block                 = "10.0.1.0/24"
  route_table_id             = oci_core_route_table.nebus_private_rt.id
  display_name               = "nebus-private-subnet"
  dns_label                  = "nebus"
  prohibit_public_ip_on_vnic = true
}
