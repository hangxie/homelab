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
