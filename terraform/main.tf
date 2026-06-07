locals {
  ssh_key         = var.ssh_public_key != "" ? var.ssh_public_key : file(pathexpand(var.ssh_public_key_file))
  masters         = { for k, v in var.nodes : k => v if startswith(k, "master-") }
  workers         = { for k, v in var.nodes : k => v if !startswith(k, "master-") }
  gpu_workers     = { for k, v in local.workers : k => v if v.gpu_pci_id != null }
  non_gpu_workers = { for k, v in local.workers : k => v if v.gpu_pci_id == null }
  worker_ceph_devices = {
    for name, config in local.non_gpu_workers :
    name => length(config.disks) > 1 ? ["/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1"] : []
  }
}

resource "proxmox_virtual_environment_vm" "node2" {
  for_each = {
    for i, k in sort(keys(var.nodes)) :
    k => merge(var.nodes[k], { vm_id = 100 + i })
    if var.nodes[k].hypervisor == "node2"
  }

  provider        = proxmox.node2
  name            = each.key
  node_name       = var.proxmox_nodes.node2.name
  started         = true
  boot_order      = var.vm.boot_order
  bios            = var.vm.bios
  machine         = var.vm.machine
  scsi_hardware   = var.vm.scsi_hardware
  stop_on_destroy = true
  vm_id           = each.value.vm_id

  agent {
    enabled = true
    timeout = "10s"
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  dynamic "disk" {
    for_each = each.value.disks
    content {
      datastore_id = var.vm.disk_storage
      interface    = "scsi${disk.key}"
      size         = disk.value
      file_id      = disk.key == 0 ? var.vm.cloud_image_id : null
    }
  }

  dynamic "hostpci" {
    for_each = each.value.gpu_pci_id != null ? [each.value.gpu_pci_id] : []
    content {
      device  = "hostpci0"
      pcie    = true
      mapping = each.value.gpu_pci_id
    }
  }

  efi_disk {
    datastore_id = var.vm.disk_storage
  }

  network_device {
    bridge = var.vm.bridge
  }

  serial_device {}

  initialization {
    datastore_id = var.vm.disk_storage
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
