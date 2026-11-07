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
    network_queues = optional(number, 4)
  })

  validation {
    condition     = var.vm.network_queues >= 1 && var.vm.network_queues <= 64 && floor(var.vm.network_queues) == var.vm.network_queues
    error_message = "network_queues must be a whole number from 1 to 64; each VM is capped at its vCPU count."
  }
}

variable "host_numa_nodes" {
  description = "Physical NUMA topology per hypervisor. CPU IDs must match lscpu; memory_mb is usable node RAM, excluding firmware reservations."
  type = map(map(object({
    cpu_affinity       = string
    memory_mb          = number
    reserved_memory_mb = optional(number, 6144)
  })))

  validation {
    condition = alltrue(flatten([
      for domains in var.host_numa_nodes : [
        for id, domain in domains :
        can(regex("^[0-7]$", id)) &&
        can(regex("^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$", domain.cpu_affinity)) &&
        alltrue([for segment in split(",", domain.cpu_affinity) : try(tonumber(split("-", segment)[0]) <= tonumber(reverse(split("-", segment))[0]), false)]) &&
        domain.memory_mb > 0 && floor(domain.memory_mb) == domain.memory_mb &&
        domain.reserved_memory_mb >= 0 && floor(domain.reserved_memory_mb) == domain.reserved_memory_mb &&
        domain.reserved_memory_mb < domain.memory_mb
      ]
    ]))
    error_message = "Host NUMA IDs must be 0-7, CPU lists must use ascending integer ranges, and memory/reserve values must be whole MiB with a positive usable memory budget."
  }
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
    hypervisor   = string # key into proxmox_nodes, e.g. "node1" or "node2"
    ip           = string
    cores        = number
    memory       = number
    numa_node    = number # physical host NUMA node; all guest vCPUs/RAM stay local
    cpu_affinity = string # host logical CPU IDs; keep SMT siblings within one VM
    # One single-entry map per disk, in scsi order: { <proxmox datastore> = "<size in GiB>" }.
    # The first entry is the OS disk and also carries the EFI and cloud-init
    # volumes; subsequent entries are the etcd (masters) or Ceph (workers) disks.
    disks       = list(map(string))
    gpu_pci_ids = optional(list(string), []) # Proxmox PCI mappings of the GPUs passed through, empty means no GPU
  }))

  validation {
    condition = alltrue([
      for node in var.nodes :
      node.cores >= 1 && floor(node.cores) == node.cores &&
      node.memory >= 1 && floor(node.memory) == node.memory &&
      node.numa_node >= 0 && node.numa_node <= 7 && floor(node.numa_node) == node.numa_node &&
      can(regex("^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$", node.cpu_affinity)) &&
      alltrue([for segment in split(",", node.cpu_affinity) : try(tonumber(split("-", segment)[0]) <= tonumber(reverse(split("-", segment))[0]), false)])
    ])
    error_message = "VM cores/memory must be positive whole numbers, numa_node must be 0-7, and CPU masks must use ascending integer ranges."
  }

  validation {
    condition = alltrue([
      for node in var.nodes : alltrue([for disk in node.disks : length(disk) == 1])
    ])
    error_message = "Each disks entry must be a single-entry map of datastore to size, e.g. { nvme = \"160\" }."
  }
}
