data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

resource "oci_core_instance" "nebus_control_plane" {
  count          = 3
  compartment_id = var.compartment_ocid

  # Distribute across Availability Domains if multiple exist in the region
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index % length(data.oci_identity_availability_domains.ads.availability_domains)].name

  display_name = "talos-cp-${count.index + 1}"
  shape        = "VM.Standard.A1.Flex"

  # ARM amp instances limited to 1 OCPU and 8GB RAM per detailed.md footprint constraints
  shape_config {
    ocpus         = 1
    memory_in_gbs = 8
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.nebus_private_subnet.id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.nebus_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = var.talos_image_ocid
    boot_volume_size_in_gbs = 50
  }

  preserve_boot_volume = false
}

resource "oci_core_instance" "nebus_bastion" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "nebus-bastion"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.nebus_private_subnet.id
    assign_public_ip = false
    # Bastion requires its own NSG if specific policies are needed, but we can reuse the cluster's base internal access rules
    nsg_ids = [oci_core_network_security_group.nebus_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = var.debian_image_ocid
    boot_volume_size_in_gbs = 50
  }

  metadata = {
    user_data = base64encode(templatefile("${path.module}/cloud-init-bastion.yaml", {
      cloudflare_token = var.bastion_cloudflare_token
    }))
  }

  preserve_boot_volume = false
}
