variable "proxmox_nodes" {
  description = "Proxmox nodes"
  type = map(object({
    name      = string
    ipv4      = string
    api_token = string
    endpoint  = string
  }))
  sensitive = true
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init"
  type        = string
  default     = ""
}

variable "ssh_public_key_file" {
  description = "Path to SSH public key file"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vm" {
  description = "Virtual machine's settings"
  type = object({
    bios           = string
    bridge         = string
    boot_order     = list(string)
    gateway        = string
    machine        = string
    scsi_hardware  = string
    cloud_image_id = string
    disk_storage   = string
  })
}

variable "storage_classes" {
  description = "Storage classes to install, in priority order. The first entry is set as the default StorageClass."
  type        = list(string)
  default     = ["rook-ceph"]

  validation {
    condition = alltrue([
      for storage_class in var.storage_classes :
      contains(["rook-ceph"], storage_class)
    ])
    error_message = "storage_classes can only contain rook-ceph."
  }
}

variable "kube_api_vip" {
  description = "Cilium L2 LoadBalancer VIP used for the final Kubernetes API kubeconfig endpoint after all control-plane nodes have joined."
  type        = string
  default     = "192.168.0.218"
}

variable "nodes" {
  description = "All Kubernetes node definitions. Names prefixed with 'master-' are treated as control-plane nodes."
  type = map(object({
    hypervisor = string # key into proxmox_nodes, e.g. "node1" or "node2"
    ip         = string
    cores      = number
    memory     = number
    disks      = list(string)     # first entry is the OS disk; subsequent entries are Ceph/data disks
    gpu_pci_id = optional(string) # GPU's PCI id, null means no GPU
  }))
}
