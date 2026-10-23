terraform {
  required_providers {
    openstack = {
      source = "terraform-provider-openstack/openstack"
    }
  }
}

# Uses the clouds.yaml from your Application Credential (see the Hack@UCF
# "OpenStack with Terraform" guide), placed next to this file.
provider "openstack" {
  cloud = "openstack"
}

module "lab" {
  source = "../.."

  name                  = "lab"
  image_id              = "82fb1323-3630-4d32-8634-c4131a5259dd" # pfSense 2.7.2 (installed, raw)
  flavor_name           = "m1.small"
  boot_volume_size      = 15
  external_network_name = "External Network"

  lan_networks = [
    { name = "lan", cidr = "192.168.1.0/24" },  # pfSense LAN  (vtnet1)
    { name = "dmz", cidr = "192.168.20.0/24" }, # pfSense OPT1 (vtnet2)
  ]
}

# A workload VM on the LAN, using pfSense as its default gateway.
resource "openstack_compute_instance_v2" "client" {
  name         = "lab-client"
  image_id     = "2f97cf75-3272-4116-b47c-ff791e970008" # Debian 12
  flavor_name  = "m1.small"
  config_drive = true # metadata service is unreachable on networks without a Neutron router

  # Lab-only: fixed console/SSH password for the "debian" user. The runcmd
  # prints the route and an outbound check to the console log so you can
  # confirm the path through pfSense without logging in.
  user_data = <<-EOT
    #cloud-config
    ssh_pwauth: true
    chpasswd:
      expire: false
      users:
        - name: debian
          password: ${var.client_password}
          type: text
    runcmd:
      - echo "=== lab-client route ===" > /dev/console
      - ip route > /dev/console
      - sh -c 'curl -sS -m 10 -o /dev/null -w "=== egress check: HTTP %%{http_code} via %%{remote_ip} ===\n" https://deb.debian.org/ > /dev/console 2>&1 || echo "=== egress check FAILED ===" > /dev/console'
  EOT

  network {
    uuid = module.lab.lan_networks["lan"].network_id
  }
}

variable "client_password" {
  description = "Password for the debian user on lab-client."
  type        = string
  default     = "LabClient!2026"
  sensitive   = true
}

output "pfsense_public_ip" {
  value = module.lab.floating_ip
}

output "lan_networks" {
  value = module.lab.lan_networks
}
