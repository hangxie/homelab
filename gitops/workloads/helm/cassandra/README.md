# Cassandra

This workload uses the K8ssandra operator chart and a `K8ssandraCluster`
custom resource. The Cassandra data plane runs as a three-node Cassandra 5.0
datacenter named `dc1` with 10 GiB Rook-Ceph block PVCs per node.

## Endpoints

- Stable compatibility endpoint: `cassandra.cassandra.svc.cluster.local:9042`
- Operator endpoint: `cassandra-dc1-service.cassandra.svc.cluster.local:9042`
- Superuser secret: `cassandra-admin` (`username` and `password` keys)

The compatibility Service keeps the old `cassandra` DNS name for out-of-repo
clients that were using the Bitnami chart service.

## Migrating Existing Keyspaces

Changing from the Bitnami chart to K8ssandra creates new StatefulSets and PVCs.
The old Bitnami PVCs are not reused by the operator. For a data-preserving
migration, export before merging this chart change, then import after the new
`K8ssandraCluster` is Ready.

1. Pause Argo sync for `wl-cassandra` or hold this Git change until the backup
   has been captured.
2. Export non-system keyspace schema and data from the current Bitnami cluster.
   Use the existing `cassandra-admin` Vault-backed password:

   ```bash
   CASSANDRA_PASSWORD="$(
     kubectl -n cassandra get secret cassandra-admin \
       -o jsonpath='{.data.cassandra-password}' | base64 -d
   )"

   kubectl -n cassandra exec cassandra-0 -- \
     cqlsh -u cassandra -p "$CASSANDRA_PASSWORD" -e 'DESC KEYSPACES'

   kubectl -n cassandra exec cassandra-0 -- \
     cqlsh -u cassandra -p "$CASSANDRA_PASSWORD" -e 'DESC SCHEMA' \
     > cassandra-schema.cql
   ```

   Exclude `system`, `system_auth`, `system_distributed`, `system_schema`, and
   `system_traces`. For small keyspaces, export each table with `COPY`. For
   larger keyspaces, take `nodetool snapshot` backups on each old pod and load
   the snapshot SSTables into the new cluster with `sstableloader`.
3. Merge and sync this workload. Wait for:

   ```bash
   kubectl -n cassandra get k8ssandracluster cassandra
   kubectl -n cassandra get cassdc dc1 -o jsonpath='{.status.cassandraOperatorProgress}'
   ```

   The datacenter is ready when the second command returns `Ready`.
4. Recreate application keyspaces with replication for `dc1`, then load the
   exported data into `cassandra.cassandra.svc.cluster.local:9042`.
5. Restart any Cassandra clients so drivers refresh contact points and token
   metadata.

If the Cassandra workload is disposable, skip the export/import and let Argo
prune the old Bitnami resources during the sync.
