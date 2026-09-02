# AGENTS.md

See `README.md` for architecture, bootstrap flow, and rebuild modes.

## Rules

- **No AI/agent attribution in repo artifacts.** No `Co-Authored-By`, `Generated with ...`, or similar in commits, PRs, issues, or docs.
- **Short commit messages.** Title + 3-6 line body. Analysis, rationale, and test plan go in the PR description.
- **Fix in place.** Edit the existing file/resource. No parallel versions, shim files, or "v2" copies — clean up the old thing first.
- **No one-off migration code.** Operator resets or redeploys per README; don't add transition branches or backfill jobs.
- **HF token always required.** Every HuggingFace download path reads the token and fails loudly if missing.
- **No hard-wrapped Markdown.** One line per paragraph or list item. Rewrapping turns a one-word edit into a whole-block diff.

## Ownership (don't cross)

- Terraform → infra only. No K8s objects.
- Ansible → bootstrap only; hands reconciliation to Argo CD after applying the root app. Exception: Cilium (full lifecycle).
- Argo CD → everything else in-cluster, including its own chart/config.
- Vault → only persistent source of truth besides Git. Secrets enter via `ExternalSecret` against `vault-homelab` — never literal Secret manifests.

## Adding things

- **Helm workload:** create `gitops/workloads/helm/<name>/{config.json,values.yaml}` (+ `extras/`), add `- name: <name>` to `gitops/cluster/applications/workloads-helm.yaml`. `config.json` schema: `chart_repo` / `chart_name` / `chart_version` only.
- **Raw workload:** create `gitops/workloads/raw/<name>/manifests/*.yaml`, add `- name: <name>` to `workloads-raw.yaml`.
- **Disable a workload:** comment out its line. Pruning is automatic.
- **Platform component:** edit `gitops/platform/<component>/`. Respect sync waves in `gitops/cluster/applications/<component>.yaml`.
- **New secret path:** add to `scripts/vault-secrets.template.yaml`, re-run `scripts/seed-vault.sh`. `generate: false` entries must be `vault kv put` first.

## Commands

```bash
pre-commit run --all-files                       # before every commit
terraform -chdir=terraform {init,apply,destroy}  # no root .tf
scripts/seed-certs.sh                            # needs CF_API_TOKEN or VAULT_ADDR+VAULT_TOKEN; issues cert if certs/ is empty
```

Bootstrap, reset/shutdown, Vault seeding, and secret rotation: see `README.md` — the commands there carry the caveats (`--regenerate`, rolling pods after a force-sync).

## Change workflow (bug fixes and new features)

1. **Disable Argo CD sync** on the affected app *and* on `root` — otherwise the App-of-Apps restores the child's syncPolicy:
   ```bash
   for app in root <name>; do
     kubectl -n argocd patch app "$app" --type=merge \
       -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":false}}}}'
   done
   ```
2. **Validate locally** — apply changes directly with `kubectl` until the app is running correctly.
3. **Reflect the change in code** — edit the GitOps manifests/values to match the working local state.
4. **Branch → commit → PR** — short commit message (see Rules), analysis and rationale in the PR description.
5. **Re-enable Argo CD sync** on both apps after merge. Note this in the **PR description only**, not the commit message.

## Gotchas

- Root app uses `directory.recurse: false` — only `Application`/`ApplicationSet` manifests in `gitops/cluster/applications/`.
- `workloads-helm` ApplicationSet is multi-source (chart + `$values` + `extras/`). Don't collapse.
- Gateway terminates TLS on 443; upstream services are plain HTTP. New `HTTPRoute`s must set `sectionName: https` on the `parentRef` — port 80 only 301-redirects.
- `ansible/inventory.ini` is generated from `terraform/templates/inventory.tftpl`. Don't hand-edit.
- StatefulSet `volumeClaimTemplates` PVCs aren't Argo-tracked; they survive a prune. Delete by hand.

## Response style

- Lead with the answer. No preambles, filler, or decorative formatting.
- Include details only when necessary or requested.
