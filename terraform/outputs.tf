output "master_ips" {
  description = "IP addresses of master nodes"
  value = {
    for k, v in var.nodes : k => v.ip if startswith(k, "master-")
  }
}

output "worker_ips" {
  description = "IP addresses of worker nodes"
  value = {
    for k, v in var.nodes : k => v.ip if !startswith(k, "master-")
  }
}

# Generate Ansible inventory
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tftpl", {
    masters              = local.masters
    workers              = local.workers
    non_gpu_workers      = local.non_gpu_workers
    gpu_workers          = local.gpu_workers
    storage_classes_json = jsonencode(var.storage_classes)
    kube_api_vip         = var.kube_api_vip
  })
  filename = "${path.module}/../ansible/inventory.ini"
}

output "vm_placement" {
  description = "Reviewed host CPU masks, NUMA binding, and virtio queues; CPU masks are not host-kernel isolation."
  value = {
    for name, node in var.nodes : name => {
      hypervisor   = node.hypervisor
      numa_node    = node.numa_node
      cpu_affinity = node.cpu_affinity
      memory_mb    = node.memory
      queues       = min(node.cores, var.vm.network_queues)
    }
  }
}
