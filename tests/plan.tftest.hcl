mock_provider "openstack" {
  mock_data "openstack_networking_network_v2" {
    defaults = { id = "ext-net-id" }
  }
  mock_data "openstack_images_image_v2" {
    defaults = { id = "pfsense-image-id" }
  }
}

variables {
  name                  = "t"
  image_name            = "pfsense"
  flavor_name           = "m1.small"
  external_network_name = "public"
  lan_networks = [
    { name = "lan", cidr = "192.168.1.0/24" },
    { name = "dmz", cidr = "10.20.0.0/24", gateway_ip = "10.20.0.254", dns_nameservers = ["1.1.1.1"] },
  ]
}

run "routed_defaults" {
  command = plan

  assert {
    condition     = local.wan_fixed_ip == "10.255.255.10"
    error_message = "WAN IP should default to .10 of the transit subnet"
  }
  assert {
    condition     = openstack_networking_port_v2.lan["lan"].fixed_ip[0].ip_address == "192.168.1.1"
    error_message = "LAN gateway should default to first host"
  }
  assert {
    condition     = openstack_networking_subnet_v2.lan["lan"].dns_nameservers == tolist(["192.168.1.1"])
    error_message = "LAN DNS should default to pfSense"
  }
  assert {
    condition     = openstack_networking_port_v2.lan["dmz"].fixed_ip[0].ip_address == "10.20.0.254"
    error_message = "explicit gateway_ip should be honoured"
  }
  assert {
    condition     = length(openstack_networking_floatingip_v2.wan) == 1 && length(openstack_networking_router_v2.edge) == 1
    error_message = "routed mode should create router and FIP"
  }
  assert {
    condition     = length(openstack_compute_instance_v2.pfsense.network) == 3
    error_message = "pfSense should have WAN + 2 LAN NICs"
  }
}

run "direct_mode" {
  command = plan
  variables {
    wan_mode         = "direct"
    boot_volume_size = 16
  }

  assert {
    condition     = length(openstack_networking_router_v2.edge) == 0 && length(openstack_networking_floatingip_v2.wan) == 0
    error_message = "direct mode should not create router/FIP"
  }
  assert {
    condition     = openstack_networking_port_v2.wan.network_id == "ext-net-id"
    error_message = "direct WAN should land on the external network"
  }
  assert {
    condition     = length(openstack_compute_instance_v2.pfsense.block_device) == 1
    error_message = "boot_volume_size should boot from volume"
  }
}

run "bad_mode" {
  command = plan
  variables {
    wan_mode = "bridged"
  }
  expect_failures = [var.wan_mode]
}
