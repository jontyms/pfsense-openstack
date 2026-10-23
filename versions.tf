terraform {
  required_version = ">= 1.3"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.53, < 4.0"
    }
  }
}
