# pfsense-openstack

Terraform/OpenTofu module that builds an isolated OpenStack network with a
pfSense VM as its router/firewall.

```
                External Network
                       │
              ┌────────┴────────┐   (wan_mode = "routed", default)
              │  Neutron router │
              └────────┬────────┘
                transit 10.255.255.0/28        ← floating IP → pfSense WAN (.10)
                       │
                 ┌─────┴─────┐
                 │  pfSense  │  vtnet0 = WAN
                 └─┬───────┬─┘  vtnet1 = LAN, vtnet2.. = OPT1..
       192.168.1.0/24     192.168.20.0/24 ...
         (gw .1)              (gw .1)
```

With `wan_mode = "direct"`, the router and transit network are skipped and
the pfSense WAN port is plugged straight into the external network (or
`wan_network_id`).

## Usage

```hcl
module "lab" {
  source = "github.com/jontyms/pfsense-openstack"

  name                  = "lab"
  image_id              = "<installed pfSense image>"
  flavor_name           = "m1.small"
  boot_volume_size      = 15
  external_network_name = "External Network"

  lan_networks = [
    { name = "lan", cidr = "192.168.1.0/24" },
    { name = "dmz", cidr = "192.168.20.0/24", mtu = 1450 },
  ]
}
```

See `examples/basic` for a full example, including a client VM.

## Getting started

New to Terraform on Hack@UCF OpenStack? Start with the
[OpenStack with Terraform guide](https://help.hackucf.org/guides/OpenStack%20with%20Terraform/).
It covers installing Terraform, creating an **Application Credential**,
downloading its `clouds.yaml`, and the `init` → `plan` → `apply` workflow.
This module uses the same setup:

```sh
git clone https://github.com/jontyms/pfsense-openstack.git
cd pfsense-openstack/examples/basic
cp ~/Downloads/clouds.yaml .      # from your Application Credential
terraform init
terraform plan
terraform apply
```

* **Choose the project when you create the credential.** An Application
  Credential is tied to the project you were in when you created it in
  Horizon. Switch to the project you want to deploy into first.
* **Check the image ID and network name.** Change `image_id` and
  `external_network_name` in `examples/basic/main.tf` if your project uses
  different ones.
* **Provider version:** the module supports OpenStack provider `>= 1.53`, so
  the guide's `~> 1.53.0` pin works. OpenTofu works too.

## How it works / things to know

* **Port security is disabled on all pfSense ports.** Neutron would otherwise
  drop forwarded traffic, because its source/destination isn't the port's own
  IP. pfSense does the filtering. The project needs the `port-security`
  extension and permission to disable it.
* **NIC order is deterministic.** WAN is first, then `lan_networks` in list
  order. pfSense assigns `vtnet0`, `vtnet1`, and so on.
* **The defaults match a factory pfSense config.** That config has WAN on
  DHCP, LAN static at `192.168.1.1/24`, and automatic outbound NAT. The
  transit subnet hands the WAN its fixed IP and gateway over DHCP. pfSense
  CE has no cloud-init, so the module can't configure pfSense itself. Images
  that aren't factory-fresh need the checklist below.
* **Neutron does DHCP on the LANs, not pfSense.** Client VMs keep port
  security, so they must use the IP Neutron allocated. Neutron DHCP hands out
  pfSense as the gateway and, by default, as DNS. Leave the pfSense DHCP
  server **off** on these interfaces.
* **The metadata service** is reachable on the LANs only if your cloud
  enables isolated metadata on the DHCP agent (Hack@UCF's does: clients get
  a `169.254.169.254` route via `.2`). Otherwise use `config_drive = true`.
* **NAT:** pfSense must do outbound NAT, because the Neutron router only
  SNATs the transit subnet. If you turn NAT off on purpose, set
  `route_lans_via_router = true` so replies can find their way back.

## pfSense setup after `apply`

The web interface is blocked on WAN by default. For first access, open the
pfSense console (Horizon or `openstack console url show`), choose `8`
(Shell), and run `pfctl -d`. Then browse to `https://<floating_ip>` and log
in as `admin` / `pfsense`. pf turns back on at the next rule reload, so do
step 2 first.

1. **Setup wizard:** run it, and set a new admin password.
2. **Interfaces → WAN:** untick *Block private networks* and *Block bogon
   networks*. Neutron keeps the client's real source IP, which is usually
   private.
3. **Firewall → Rules → WAN:** pass TCP from your management CIDR to *WAN
   address* on ports 443 and 22.
4. **Interfaces → LAN:** set *IPv4 Configuration Type* to **Static IPv4**,
   use the LAN's `gateway_ip`/prefix, and set *IPv4 Upstream gateway* to
   **None**. Set *IPv6 Configuration Type* to **None**.
5. **Firewall → NAT → Outbound:** set the mode to **Automatic**.
6. **Interfaces → Assignments:** for each extra LAN, add `vtnet2`, `vtnet3`,
   and so on. Configure each like step 4 with its `gateway_ip` from the
   `lan_networks` output, then add a pass rule under Firewall → Rules.
7. **MTU:** set each pfSense interface's MTU to the Neutron network MTU
   (`openstack network show <net> -c mtu`; 8942 on Hack@UCF). Alternatively,
   set `mtu = 1500` on the LANs. With a mismatch, small packets work but
   large ones from clients are dropped.
8. **System → Cert Manager:** if the image wasn't installed fresh, generate a
   new web interface certificate and select it in System → Advanced. A
   cloned image shares its private key with every other copy.

> **Known image issue:** the Hack@UCF `pfSense 2.7.2` image
> (`82fb1323-…`) ships with the LAN on DHCP and outbound NAT **disabled**.
> Both were set from the console when the image was built on 2024-02-17.
> It also ships a shared web interface certificate. Steps 4, 5 and 8 fix
> all three. Rebuilding the image from a clean install removes the need
> for them.

## Inputs

| Name | Default | Description |
|---|---|---|
| `name` | — | Name prefix for all resources |
| `image_id` / `image_name` | — | Installed pfSense image (one is required) |
| `flavor_name` | — | Flavor for pfSense |
| `external_network_name` | — | Upstream external network |
| `wan_mode` | `routed` | `routed` (router + transit + FIP) or `direct` |
| `wan_network_id` | external net | `direct` mode: network for the WAN port |
| `wan_fixed_ip` | transit `.10` | WAN IP |
| `transit_cidr` | `10.255.255.0/28` | `routed` mode: transit subnet |
| `transit_dns_nameservers` | `1.1.1.1, 9.9.9.9` | DNS servers for the pfSense WAN |
| `assign_floating_ip` | `true` | `routed` mode: attach a floating IP to the WAN |
| `route_lans_via_router` | `false` | `routed` mode: static routes to the LANs through pfSense |
| `lan_networks` | `192.168.1.0/24` | Ordered list of `{name, cidr, gateway_ip?, enable_dhcp?, dns_nameservers?, mtu?}` |
| `boot_volume_size` / `boot_volume_type` | `null` | Boot from a Cinder volume |
| `availability_zone`, `user_data`, `tags` | | Passed through |

## Outputs

`pfsense_instance_id`, `wan_port_id`, `wan_ip`, `floating_ip`, `router_id`,
`transit_network_id`, `lan_networks` (map of `network_id`, `subnet_id`,
`cidr`, `gateway_ip`, `pfsense_port` keyed by LAN name).

## Tests

```sh
terraform init && terraform test   # mocked plan tests, no cloud needed (or tofu)
```
