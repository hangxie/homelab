# ScyllaDB

Three-node ScyllaDB cluster managed by the ScyllaDB Operator.

- Namespace: `scylladb`
- Argo CD app: `wl-scylladb`
- Operator app: `scylla-operator`
- CQL endpoint: `scylladb-client.scylladb.svc.cluster.local:9042`
- Storage: `rook-ceph-block`, 10Gi per node

This intentionally does not reuse the old Cassandra namespace, service name, or
Vault secret path. ScyllaDB does not expose a built-in web UI/admin panel here,
so there is no `HTTPRoute` or `scripts/list-endpoints.sh` entry.
