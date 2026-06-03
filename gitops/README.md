# GitOps

Argo CD-reconciled cluster state.

- `cluster/` — root Application and per-component Application/ApplicationSet manifests.
- `platform/` — Helm values and supporting CRs for platform components.
- `workloads/` — Helm and raw workload definitions, picked up by ApplicationSets.
