terraform {
  required_version = "~> 1.14"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "= 8.2.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 5.17.0"
    }
  }

  cloud {
    organization = "risu729"

    workspaces {
      name = "nebus"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.oci_tenancy_ocid
  user_ocid        = var.oci_user_ocid
  fingerprint      = var.oci_fingerprint
  private_key_path = var.oci_private_key_path
  region           = var.oci_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
