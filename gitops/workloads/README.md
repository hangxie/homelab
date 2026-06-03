# Workloads

Two ApplicationSets generate Applications from this tree.

- `helm/<name>/` — `config.json` (chart coordinates, validated against `.schema.json`), `values.yaml`, `extras/` (ExternalSecrets, init Jobs, HTTPRoutes).
- `raw/<name>/` — `manifests/` of raw YAML.
