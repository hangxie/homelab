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
    worker_ceph_devices  = local.worker_ceph_devices
    storage_classes_json = jsonencode(var.storage_classes)
    kube_api_vip         = var.kube_api_vip
  })
  filename = "${path.module}/../ansible/inventory.ini"
}
