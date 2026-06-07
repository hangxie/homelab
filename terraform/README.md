# Terraform

Provisions Proxmox VMs, disks, and cloud-init. Writes
`../ansible/inventory.ini`, including the `kube_api_vip` value that Ansible uses
to configure the Kubernetes API VIP.
