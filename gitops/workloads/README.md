# Workloads

Two ApplicationSets generate Applications from this tree.

- `helm/<name>/` — `config.json` (`chart_repo`, `chart_name`, `chart_version` only; validated by `.schema.json`), `values.yaml`, `extras/` (ExternalSecrets, init Jobs, HTTPRoutes).
- `raw/<name>/` — `manifests/` of raw YAML.

Enabled workloads are the explicit `elements` lists in
`../../cluster/applications/workloads-helm.yaml` and
`../../cluster/applications/workloads-raw.yaml`; commenting out a line disables
and prunes that workload.
