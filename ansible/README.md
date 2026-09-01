# Ansible

Bootstraps Kubernetes (kubeadm), the API VIP, Cilium, NVIDIA host stack,
minimal Argo CD + AppProjects, the Vault bootstrap Secret, and the root
Application. The bootstrap gate waits for root/platform Argo CD Applications;
workloads are left for Argo CD to reconcile after bootstrap.

`shutdown.yml` is the counterpart: it stops workloads in reverse sync-wave order and halts the nodes, so the VMs can be powered off without leaving stateful workloads in crash recovery.
