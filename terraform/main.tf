locals {
  ssh_key         = var.ssh_public_key != "" ? var.ssh_public_key : file(pathexpand(var.ssh_public_key_file))
  masters         = { for k, v in var.nodes : k => v if startswith(k, "master-") }
  workers         = { for k, v in var.nodes : k => v if !startswith(k, "master-") }
  gpu_workers     = { for k, v in local.workers : k => v if length(v.gpu_pci_ids) > 0 }
  non_gpu_workers = { for k, v in local.workers : k => v if length(v.gpu_pci_ids) == 0 }
  # CPU IDs are host IDs; the numa block below uses guest vCPU IDs.
  numa_cpu_ids = {
    for host, domains in var.host_numa_nodes : host => {
      for id, domain in domains : id => flatten([
        for segment in split(",", domain.cpu_affinity) : try(range(
          tonumber(split("-", segment)[0]),
          tonumber(reverse(split("-", segment))[0]) + 1,
        ), [])
      ])
    }
  }
  vm_cpu_ids = {
    for name, node in var.nodes : name => flatten([
      for segment in split(",", node.cpu_affinity) : try(range(
        tonumber(split("-", segment)[0]),
        tonumber(reverse(split("-", segment))[0]) + 1,
      ), [])
    ])
  }
  allocated_cpu_ids = {
    for host, domains in var.host_numa_nodes : host => flatten([
      for name, node in var.nodes : local.vm_cpu_ids[name] if node.hypervisor == host
    ])
  }
  numa_memory_mb = {
    for host, domains in var.host_numa_nodes : host => {
      for id, domain in domains : id => sum(concat([0], [
        for node in var.nodes : node.memory
        if node.hypervisor == host && tostring(node.numa_node) == id
      ]))
    }
  }
}

resource "proxmox_virtual_environment_vm" "node2" {
  for_each = {
    for i, k in sort(keys(var.nodes)) :
    k => merge(var.nodes[k], { vm_id = 100 + i })
    if var.nodes[k].hypervisor == "node2"
  }

  provider  = proxmox.node2
  name      = each.key
  node_name = var.proxmox_nodes.node2.name
  started   = true
  on_boot   = false
  # Disk settings such as discard only take effect on a fresh QEMU process, and
  # the provider would otherwise restart every VM in the same apply — including
  # all three OSD nodes at once. Restarts are driven separately, one node at a
  # time, draining the node and waiting for Ceph to return to HEALTH_OK.
  reboot_after_update = false
  boot_order          = var.vm.boot_order
  bios                = var.vm.bios
  machine             = var.vm.machine
  scsi_hardware       = var.vm.scsi_hardware
  stop_on_destroy     = true
  vm_id               = each.value.vm_id

  agent {
    enabled = true
    timeout = "10s"
  }

  cpu {
    affinity = each.value.cpu_affinity
    cores    = each.value.cores
    numa     = true
    sockets  = 1
    type     = "host"
  }

  # Each VM fits within one physical NUMA node. Bind memory as well as CPU
  # execution; exposing guest NUMA alone does not guarantee host locality.
  numa {
    device    = "numa0"
    cpus      = "0-${each.value.cores - 1}"
    hostnodes = tostring(each.value.numa_node)
    memory    = each.value.memory
    policy    = "bind"
  }

  memory {
    dedicated = each.value.memory
    floating  = 0
  }

  operating_system {
    type = "l26"
  }

  dynamic "disk" {
    for_each = each.value.disks
    content {
      datastore_id = one(keys(disk.value))
      interface    = "scsi${disk.key}"
      size         = one(values(disk.value))
      file_id      = disk.key == 0 ? var.vm.cloud_image_id : null
      # The backing store is a single SSD behind an LVM-thin pool. Without
      # discard the guest can never return freed blocks, so the drive's FTL
      # treats every LBA ever written as live and falls into garbage collection
      # under sustained fsync load. ssd reports the correct rotation rate.
      discard = "on"
      ssd     = true
      # virtio-scsi-single gives every disk its own controller, and iothread
      # moves its submission off the main QEMU event loop. The OSD and etcd
      # disks are fsync-bound, so sharing one thread serialises their flushes.
      iothread = true
    }
  }

  dynamic "hostpci" {
    for_each = each.value.gpu_pci_ids
    content {
      device  = "hostpci${hostpci.key}"
      pcie    = true
      mapping = hostpci.value
      rombar  = false
    }
  }

  efi_disk {
    datastore_id = one(keys(each.value.disks[0]))
  }

  network_device {
    bridge = var.vm.bridge
    model  = "virtio"
    queues = min(each.value.cores, var.vm.network_queues)
  }

  serial_device {}

  initialization {
    datastore_id = one(keys(each.value.disks[0]))
    dns {
      servers = ["8.8.8.8", "1.1.1.1"]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.vm.gateway
      }
    }

    user_account {
      keys     = [trimspace(local.ssh_key)]
      username = "debian"
    }
  }

  lifecycle {
    precondition {
      condition     = try(length(local.numa_cpu_ids[each.value.hypervisor][tostring(each.value.numa_node)]) >= each.value.cores, false)
      error_message = "Every VM must select a configured host NUMA node with at least as many logical CPUs as its vCPUs."
    }
    precondition {
      condition = try(
        length(local.vm_cpu_ids[each.key]) == each.value.cores &&
        length(setsubtract(toset(local.vm_cpu_ids[each.key]), toset(local.numa_cpu_ids[each.value.hypervisor][tostring(each.value.numa_node)]))) == 0,
        false,
      )
      error_message = "Each VM CPU mask must contain exactly its vCPU count, entirely within its selected host NUMA node."
    }
    precondition {
      condition = try(
        length(local.allocated_cpu_ids[each.value.hypervisor]) == length(distinct(local.allocated_cpu_ids[each.value.hypervisor])),
        false,
      )
      error_message = "VM CPU masks on the same hypervisor must not overlap."
    }
    precondition {
      condition = try(
        local.numa_memory_mb[each.value.hypervisor][tostring(each.value.numa_node)] <=
        var.host_numa_nodes[each.value.hypervisor][tostring(each.value.numa_node)].memory_mb -
        var.host_numa_nodes[each.value.hypervisor][tostring(each.value.numa_node)].reserved_memory_mb,
        false,
      )
      error_message = "VM memory assigned to a host NUMA node must leave its configured host-memory reserve free."
    }
    precondition {
      condition = try(
        length(flatten(values(local.numa_cpu_ids[each.value.hypervisor]))) ==
        length(distinct(flatten(values(local.numa_cpu_ids[each.value.hypervisor])))),
        false,
      )
      error_message = "Host NUMA CPU lists must not contain duplicate or overlapping CPU IDs."
    }
    ignore_changes = [
      disk[0].file_id,
    ]
  }
}

# Wait for masters to be SSH-able and install agent
resource "null_resource" "wait_for_masters" {
  for_each = local.masters

  depends_on = [
    proxmox_virtual_environment_vm.node2,
  ]

  connection {
    type    = "ssh"
    user    = "debian"
    host    = each.value.ip
    agent   = true
    timeout = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cloud-init status --wait >/dev/null 2>&1 || true; sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1 && sudo systemctl start qemu-guest-agent >/dev/null 2>&1"
    ]
  }
}

# Wait for workers to be SSH-able and install agent
resource "null_resource" "wait_for_workers" {
  for_each = local.workers

  depends_on = [
    proxmox_virtual_environment_vm.node2,
  ]

  connection {
    type    = "ssh"
    user    = "debian"
    host    = each.value.ip
    agent   = true
    timeout = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cloud-init status --wait >/dev/null 2>&1 || true; sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1 && sudo systemctl start qemu-guest-agent >/dev/null 2>&1"
    ]
  }
}

# This resource is now just a anchor for Ansible
resource "null_resource" "install_agent_all_vms" {
  for_each = var.nodes

  depends_on = [
    null_resource.wait_for_masters,
    null_resource.wait_for_workers
  ]
}
