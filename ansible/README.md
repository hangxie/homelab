# Ansible

Bootstraps Kubernetes (kubeadm), the API VIP, Cilium, NVIDIA host stack,
minimal Argo CD + AppProjects, the Vault bootstrap Secret, and the root
Application. The bootstrap gate waits for root/platform Argo CD Applications;
workloads are left for Argo CD to reconcile after bootstrap.
