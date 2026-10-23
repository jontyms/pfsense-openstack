output "pfsense_instance_id" {
  description = "ID of the pfSense compute instance."
  value       = openstack_compute_instance_v2.pfsense.id
}

output "wan_port_id" {
  description = "ID of the pfSense WAN port."
  value       = openstack_networking_port_v2.wan.id
}

output "wan_ip" {
  description = "Fixed IP of the pfSense WAN interface."
  value       = one(openstack_networking_port_v2.wan.all_fixed_ips)
}

output "floating_ip" {
  description = "Floating IP associated with the pfSense WAN (routed mode with assign_floating_ip), else null."
  value       = one(openstack_networking_floatingip_v2.wan[*].address)
}

output "router_id" {
  description = "ID of the Neutron edge router (routed mode), else null."
  value       = one(openstack_networking_router_v2.edge[*].id)
}

output "transit_network_id" {
  description = "ID of the transit network (routed mode), else null."
  value       = one(openstack_networking_network_v2.transit[*].id)
}

output "lan_networks" {
  description = "Per-LAN network/subnet IDs and the pfSense gateway IP, keyed by LAN name."
  value = {
    for k, v in local.lans : k => {
      network_id   = openstack_networking_network_v2.lan[k].id
      subnet_id    = openstack_networking_subnet_v2.lan[k].id
      cidr         = v.cidr
      gateway_ip   = v.gateway_ip
      pfsense_port = openstack_networking_port_v2.lan[k].id
    }
  }
}
