variable "name" {
  description = "Name prefix applied to every resource created by this module."
  type        = string
}

variable "tags" {
  description = "Tags applied to networking resources that support them."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# pfSense instance
# ---------------------------------------------------------------------------

variable "image_id" {
  description = "ID of a pre-installed pfSense image (qcow2/raw). One of image_id or image_name is required."
  type        = string
  default     = null
}

variable "image_name" {
  description = "Name of a pre-installed pfSense image. Used when image_id is not set."
  type        = string
  default     = null
}

variable "flavor_name" {
  description = "Nova flavor for the pfSense instance (pfSense wants at least 1 vCPU / 1 GB RAM / 8 GB disk)."
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for the pfSense instance."
  type        = string
  default     = null
}

variable "boot_volume_size" {
  description = "If set, boot pfSense from a new Cinder volume of this size (GB) instead of ephemeral disk."
  type        = number
  default     = null
}

variable "boot_volume_type" {
  description = "Cinder volume type for the boot volume (only used with boot_volume_size)."
  type        = string
  default     = null
}

variable "user_data" {
  description = "Optional user data, for pfSense images that ship with a cloud-init style agent."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# WAN
# ---------------------------------------------------------------------------

variable "external_network_name" {
  description = "Name of the external (provider) network that provides upstream connectivity."
  type        = string
}

variable "wan_mode" {
  description = <<-EOT
    How the pfSense WAN interface reaches the outside world:
      routed - pfSense WAN sits on a small transit network behind a Neutron router
               with a gateway on the external network; optionally gets a floating IP.
               Works for regular (non-admin) projects.
      direct - pfSense WAN port is plugged straight into the external/provider network
               (or wan_network_id). Usually requires that the network is shared with
               your project and that you may disable port security on it.
  EOT
  type        = string
  default     = "routed"

  validation {
    condition     = contains(["routed", "direct"], var.wan_mode)
    error_message = "wan_mode must be \"routed\" or \"direct\"."
  }
}

variable "wan_network_id" {
  description = "direct mode only: network to attach the WAN port to. Defaults to the external network."
  type        = string
  default     = null
}

variable "wan_fixed_ip" {
  description = "Fixed IP for the pfSense WAN port. Defaults to .10 of the transit subnet in routed mode; Neutron picks one in direct mode."
  type        = string
  default     = null
}

variable "transit_cidr" {
  description = "routed mode only: CIDR of the transit network between the Neutron router and pfSense WAN."
  type        = string
  default     = "10.255.255.0/28"
}

variable "transit_dns_nameservers" {
  description = "routed mode only: DNS servers handed to pfSense WAN via DHCP on the transit subnet."
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

variable "assign_floating_ip" {
  description = "routed mode only: allocate a floating IP and associate it with the pfSense WAN port."
  type        = bool
  default     = true
}

variable "route_lans_via_router" {
  description = "routed mode only: add static routes on the Neutron router for every LAN CIDR via the pfSense WAN IP. Only needed if you turn off outbound NAT in pfSense."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# LAN(s)
# ---------------------------------------------------------------------------

variable "lan_networks" {
  description = <<-EOT
    Ordered list of internal networks routed by pfSense. The first entry becomes the
    pfSense LAN interface (vtnet1); further entries become OPT1, OPT2, ... (vtnet2, ...).

    gateway_ip      - pfSense address on this network (default: first host in cidr).
                      The default of 192.168.1.1 on 192.168.1.0/24 matches a stock pfSense
                      install, so the first LAN works with zero pfSense config.
    enable_dhcp     - let Neutron run DHCP on this subnet (recommended; disable the pfSense
                      DHCP server on this interface to avoid two DHCP servers).
    dns_nameservers - DNS handed out by Neutron DHCP (default: the pfSense gateway IP).
  EOT
  type = list(object({
    name            = string
    cidr            = string
    gateway_ip      = optional(string)
    enable_dhcp     = optional(bool, true)
    dns_nameservers = optional(list(string))
    mtu             = optional(number)
  }))
  default = [
    { name = "lan", cidr = "192.168.1.0/24" },
  ]

  validation {
    condition     = length(var.lan_networks) > 0
    error_message = "At least one LAN network is required."
  }

  validation {
    condition     = length(distinct([for n in var.lan_networks : n.name])) == length(var.lan_networks)
    error_message = "lan_networks names must be unique."
  }
}
