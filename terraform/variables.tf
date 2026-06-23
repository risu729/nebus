variable "oci_tenancy_ocid" {
  type        = string
  description = "The tenancy OCID for OCI"
}

variable "oci_user_ocid" {
  type        = string
  description = "The user OCID for OCI"
}

variable "oci_fingerprint" {
  type        = string
  description = "The fingerprint for the OCI API key"
  sensitive   = true
}

variable "oci_private_key_path" {
  type        = string
  description = "The path to the OCI API private key"
}

variable "oci_region" {
  type        = string
  description = "The target OCI region"
}

variable "cloudflare_api_token" {
  type        = string
  description = "The Cloudflare API Token"
  sensitive   = true
}

variable "compartment_ocid" {
  type        = string
  description = "The target OCI compartment OCID"
}

variable "talos_image_ocid" {
  type        = string
  description = "The OCID of the custom Talos ARM64 image"
}

variable "debian_image_ocid" {
  type        = string
  description = "The OCID of the standard Debian image for the AMD Micro bastion"
}

variable "bastion_cloudflare_token" {
  type        = string
  description = "The token for the Cloudflared tunnel deployed on the bastion"
  sensitive   = true
}
