# Unused today - every VM lands on node2. Kept as the reference for a second
# hypervisor: aliases can't come from a for_each, so each one needs a literal
# block here plus a matching VM resource in main.tf.
provider "proxmox" {
  alias     = "node1"
  endpoint  = var.proxmox_nodes.node1.endpoint
  api_token = var.proxmox_nodes.node1.api_token
  insecure  = true

  ssh {
    agent    = true
    username = "root"
    node {
      name    = var.proxmox_nodes.node1.name
      address = var.proxmox_nodes.node1.ipv4
    }
  }
}
provider "proxmox" {
  alias     = "node2"
  endpoint  = var.proxmox_nodes.node2.endpoint
  api_token = var.proxmox_nodes.node2.api_token
  insecure  = true

  ssh {
    agent    = true
    username = "root"
    node {
      name    = var.proxmox_nodes.node2.name
      address = var.proxmox_nodes.node2.ipv4
    }
  }
}
