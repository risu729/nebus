resource "oci_identity_dynamic_group" "nebus_nodes" {
  name           = "nebus-nodes-group"
  description    = "Dynamic group grouping all Talos nodes in the cluster compartment"
  compartment_id = var.oci_tenancy_ocid # Must be created at the tenancy level
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

resource "oci_identity_policy" "nebus_ccm_policy" {
  name           = "nebus-ccm-policy"
  description    = "Permissions allowing the OCI Cloud Controller Manager (CCM) to provision load balancers via instance principals"
  compartment_id = var.compartment_ocid
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.nebus_nodes.name} to manage load-balancers in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.nebus_nodes.name} to use virtual-network-family in compartment id ${var.compartment_ocid}",
  ]
}

resource "oci_identity_policy" "nebus_storage_policy" {
  name           = "nebus-storage-policy"
  description    = "Permissions allowing database operators to stream backups to OCI Object Storage"
  compartment_id = var.compartment_ocid
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.nebus_nodes.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name='nebus-backups'",
  ]
}
