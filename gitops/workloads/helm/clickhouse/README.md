# ClickHouse

Small ClickHouse cluster deployed as the Trino replacement workload. The
workload installs the official ClickHouse operator Helm chart and applies
operator-managed `KeeperCluster` and `ClickHouseCluster` resources from
`extras/`.

- Namespace: `clickhouse`
- Argo CD app: `wl-clickhouse`
- HTTP endpoint: `https://clickhouse.homelab.xiehang.com`
- In-cluster HTTP endpoint: `clickhouse.clickhouse.svc.cluster.local:8123`
- In-cluster native TCP endpoint: `clickhouse.clickhouse.svc.cluster.local:9000`
- Credential secret: `clickhouse-credentials` (`username` and `password` keys)
- Vault path: `homelab/clickhouse/credentials`
- Storage: `rook-ceph-block`, 20Gi per ClickHouse replica and 5Gi per Keeper
  replica

The cluster runs one shard with two ClickHouse replicas and a three-replica
ClickHouse Keeper ensemble, pinned to official `clickhouse/clickhouse-server`
and `clickhouse/clickhouse-keeper` image tag `25.7`. TLS terminates at the
shared Gateway; upstream ClickHouse HTTP traffic is plain HTTP on port 8123.

The Vault value sets the `default` user password through the operator's
`defaultUserPassword` setting. Rotating `homelab/clickhouse/credentials` later
refreshes the Kubernetes Secret, but it does not change an already initialized
ClickHouse user by itself; use `ALTER USER` inside ClickHouse or reset the
workload PVCs and redeploy.

## Trino Replacement And Rollback

`wl-clickhouse` replaces `wl-trino` in
`gitops/cluster/applications/workloads-helm.yaml`. The Trino workload files stay
in `gitops/workloads/helm/trino/` for reference and rollback.

To roll back, comment out `- name: clickhouse` and uncomment `- name: trino` in
the ApplicationSet list, then let Argo CD sync. Argo CD prunes the operator,
cluster CRs, compatibility Service, and route. Check for retained
operator-created PVCs after pruning and delete them explicitly before
recreating the workload if a clean storage reset is required.

ClickHouse is not a drop-in SQL gateway for Trino catalogs. Migrate downstream
clients to use the HTTP endpoint or native TCP endpoint directly, update SQL
dialects where needed, and move any Hive/MySQL catalog queries to explicit
ClickHouse tables, dictionaries, or integrations before disabling Trino in an
environment that still depends on those catalogs.
