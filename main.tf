locals {
  routed = var.wan_mode == "routed"

  # Keyed by name for for_each; var.lan_networks keeps the NIC order.
  lans = {
    for n in var.lan_networks : n.name => merge(n, {
      gateway_ip      = coalesce(n.gateway_ip, cidrhost(n.cidr, 1))
      dns_nameservers = coalesce(n.dns_nameservers, [coalesce(n.gateway_ip, cidrhost(n.cidr, 1))])
    })
  }

  wan_fixed_ip = local.routed ? coalesce(var.wan_fixed_ip, cidrhost(var.transit_cidr, 10)) : var.wan_fixed_ip
  image_id     = var.image_id != null ? var.image_id : data.openstack_images_image_v2.pfsense[0].id
}

data "openstack_networking_network_v2" "external" {
  name     = var.external_network_name
  external = local.routed ? true : null
}

data "openstack_images_image_v2" "pfsense" {
  count       = var.image_id == null ? 1 : 0
  name        = var.image_name
  most_recent = true

  lifecycle {
    precondition {
      condition     = var.image_name != null
      error_message = "Set either image_id or image_name."
    }
  }
}

# ---------------------------------------------------------------------------
# WAN: transit network + Neutron router (routed mode)
# ---------------------------------------------------------------------------

resource "openstack_networking_router_v2" "edge" {
  count               = local.routed ? 1 : 0
  name                = "${var.name}-edge"
  external_network_id = data.openstack_networking_network_v2.external.id
  tags                = var.tags
}

resource "openstack_networking_network_v2" "transit" {
  count          = local.routed ? 1 : 0
  name           = "${var.name}-transit"
  admin_state_up = true
  tags           = var.tags
}

resource "openstack_networking_subnet_v2" "transit" {
  count           = local.routed ? 1 : 0
  name            = "${var.name}-transit"
  network_id      = openstack_networking_network_v2.transit[0].id
  cidr            = var.transit_cidr
  ip_version      = 4
  gateway_ip      = cidrhost(var.transit_cidr, 1)
  enable_dhcp     = true
  dns_nameservers = var.transit_dns_nameservers
  tags            = var.tags
}

resource "openstack_networking_router_interface_v2" "transit" {
  count     = local.routed ? 1 : 0
  router_id = openstack_networking_router_v2.edge[0].id
  subnet_id = openstack_networking_subnet_v2.transit[0].id
}

# pfSense is the firewall, so Neutron port security (anti-spoofing + security
# groups) is disabled on all of its ports. Without this Neutron drops any packet
# pfSense forwards whose source/destination IP isn't the port's own address.
resource "openstack_networking_port_v2" "wan" {
  name                  = "${var.name}-pfsense-wan"
  network_id            = local.routed ? openstack_networking_network_v2.transit[0].id : coalesce(var.wan_network_id, data.openstack_networking_network_v2.external.id)
  admin_state_up        = true
  port_security_enabled = false
  no_security_groups    = true
  tags                  = var.tags

  dynamic "fixed_ip" {
    for_each = local.routed || local.wan_fixed_ip != null ? [1] : []
    content {
      subnet_id  = local.routed ? openstack_networking_subnet_v2.transit[0].id : null
      ip_address = local.wan_fixed_ip
    }
  }
}

resource "openstack_networking_floatingip_v2" "wan" {
  count   = local.routed && var.assign_floating_ip ? 1 : 0
  pool    = data.openstack_networking_network_v2.external.name
  port_id = openstack_networking_port_v2.wan.id
  tags    = var.tags

  # The port's subnet must be attached to the router before a FIP can map to it.
  depends_on = [openstack_networking_router_interface_v2.transit]
}

resource "openstack_networking_router_route_v2" "lan" {
  for_each         = local.routed && var.route_lans_via_router ? local.lans : {}
  router_id        = openstack_networking_router_v2.edge[0].id
  destination_cidr = each.value.cidr
  next_hop         = local.wan_fixed_ip

  depends_on = [openstack_networking_router_interface_v2.transit]
}

# ---------------------------------------------------------------------------
# LAN networks (pfSense is the default gateway)
# ---------------------------------------------------------------------------

resource "openstack_networking_network_v2" "lan" {
  for_each       = local.lans
  name           = "${var.name}-${each.key}"
  admin_state_up = true
  mtu            = each.value.mtu
  tags           = var.tags
}

resource "openstack_networking_subnet_v2" "lan" {
  for_each        = local.lans
  name            = "${var.name}-${each.key}"
  network_id      = openstack_networking_network_v2.lan[each.key].id
  cidr            = each.value.cidr
  ip_version      = 4
  gateway_ip      = each.value.gateway_ip
  enable_dhcp     = each.value.enable_dhcp
  dns_nameservers = each.value.dns_nameservers
  tags            = var.tags
}

resource "openstack_networking_port_v2" "lan" {
  for_each              = local.lans
  name                  = "${var.name}-pfsense-${each.key}"
  network_id            = openstack_networking_network_v2.lan[each.key].id
  admin_state_up        = true
  port_security_enabled = false
  no_security_groups    = true
  tags                  = var.tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.lan[each.key].id
    ip_address = each.value.gateway_ip
  }
}

# ---------------------------------------------------------------------------
# pfSense instance
# ---------------------------------------------------------------------------

resource "openstack_compute_instance_v2" "pfsense" {
  name              = "${var.name}-pfsense"
  flavor_name       = var.flavor_name
  image_id          = var.boot_volume_size == null ? local.image_id : null
  availability_zone = var.availability_zone
  user_data         = var.user_data

  dynamic "block_device" {
    for_each = var.boot_volume_size != null ? [1] : []
    content {
      uuid                  = local.image_id
      source_type           = "image"
      destination_type      = "volume"
      volume_size           = var.boot_volume_size
      volume_type           = var.boot_volume_type
      boot_index            = 0
      delete_on_termination = true
    }
  }

  # NIC order matters: pfSense assigns vtnet0 = WAN, vtnet1 = LAN, vtnet2+ = OPTn.
  network {
    port = openstack_networking_port_v2.wan.id
  }

  dynamic "network" {
    for_each = var.lan_networks
    content {
      port = openstack_networking_port_v2.lan[network.value.name].id
    }
  }

  lifecycle {
    # pfSense may change its own image/user_data view after upgrades; don't rebuild.
    ignore_changes = [image_id, user_data]
  }
}
