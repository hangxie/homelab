# ClickHouse

Small ClickHouse cluster that runs alongside Trino. The workload installs the official ClickHouse operator Helm chart and applies operator-managed `KeeperCluster` and `ClickHouseCluster` resources from `extras/`.

- Namespace: `clickhouse`
- Argo CD app: `wl-clickhouse`
- HTTP endpoint: `https://clickhouse.homelab.xiehang.com`
- In-cluster HTTP endpoint: `clickhouse.clickhouse.svc.cluster.local:8123`
- In-cluster native TCP endpoint: `clickhouse.clickhouse.svc.cluster.local:9000`
- Credential secret: `clickhouse-credentials` (`username` and `password` keys)
- Vault path: `homelab/clickhouse/credentials`
- ClickHouse replica sizing: 1 CPU and 4Gi memory requests, 4 CPU and 8Gi memory limits, and 40Gi `rook-ceph-block` storage
- Keeper replica storage: 5Gi `rook-ceph-block`

The cluster runs one shard with two ClickHouse replicas and a three-replica
ClickHouse Keeper ensemble, pinned to official `clickhouse/clickhouse-server`
and `clickhouse/clickhouse-keeper` image tag `25.7`. TLS terminates at the
shared Gateway; upstream ClickHouse HTTP traffic is plain HTTP on port 8123.

The Vault value sets the `default` user password through the operator's
`defaultUserPassword` setting. Rotating `homelab/clickhouse/credentials` later
refreshes the Kubernetes Secret, but it does not change an already initialized
ClickHouse user by itself; use `ALTER USER` inside ClickHouse or reset the
workload PVCs and redeploy.

## Built-in Dashboard

The built-in `/dashboard` queries `system.metric_log` and `system.asynchronous_metric_log`. Keep both enabled: removing them makes the charts return HTTP 500 (`CANNOT_EXTRACT_TABLE_STRUCTURE`) even when authentication succeeds. Both logs flush once per minute and retain one day of history; metric samples stay at one-second intervals so the dashboard rate charts remain accurate. `text_log` stays disabled because Kubernetes captures console logs.

## Memory Guardrails

`max_server_memory_usage_to_ram_ratio` is `0.8`, so ClickHouse tracks at most 6.4Gi of the 8Gi container limit and leaves headroom for allocations the memory tracker does not account for. Without that headroom the kernel OOM-kills the container before the server ever refuses a query.

The `default` profile in `settings.extraUsersConfig` caps a single query at 4Gi and spills aggregation and sort to `/var/lib/clickhouse` at 2Gi. The operator renders that block into `/etc/clickhouse-server/users.d/99-extra-users-config.yaml`; the directory does not exist at all until `extraUsersConfig` is set. A query past the cap fails with `MEMORY_LIMIT_EXCEEDED` (code 241) rather than taking the pod down.

Spill uses the 40Gi data PVC, so the temporary files compete with table data. Raise the volume before raising the per-query cap.

## Trino

Trino's `clickhouse` catalog reads every ClickHouse database (each appears as a schema) as the read-only `trino` user: `SELECT` and `SHOW` grants only. Its password lives in Vault at `homelab/clickhouse/trino`; the `trino-clickhouse-bootstrap` Sync-hook Job in the `trino` namespace creates the user with the `default` credentials and re-applies its password and grants on every sync. SQL users sit in ClickHouse's Keeper-replicated access storage, so the one user covers both replicas.

## Disabling

Comment out `- name: clickhouse` in `gitops/cluster/applications/workloads-helm.yaml` and let Argo CD sync; it prunes the operator, cluster CRs, Service and route. Operator-created PVCs are retained; delete them by hand for a clean storage reset. Comment out Trino's `clickhouse` catalog at the same time, or its queries fail.
