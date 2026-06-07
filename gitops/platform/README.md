# Platform

Per-component values and CR manifests. Each subdirectory pairs with a sibling Application/ApplicationSet in `../cluster/applications/`.

Layout:

- `<component>/values.yaml` — Helm values, consumed via the multi-source `$values` ref.
- `<component>/<subdir>/` — additional CRs applied as a second Application (e.g. `cert-manager/config/`, `external-secrets/stores/`, `rook-ceph/cluster/`).
