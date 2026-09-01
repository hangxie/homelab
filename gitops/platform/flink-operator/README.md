# Flink operator

The Apache Flink Kubernetes Operator, watching the `flink` namespace. There is no long-lived Flink cluster: each `FlinkDeployment` brings its own JobManager and TaskManagers, and `FlinkSessionJob` submits into a session cluster created the same way.

`extras/` provisions the job namespace and the `flink-checkpoints` ObjectBucketClaim. Rook creates the bucket on Ceph RGW and drops a `flink-checkpoints` Secret into `flink` carrying `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

## Deletion protection

The `flink` namespace, the `flink-checkpoints` OBC and the `flink-operator` Application all carry `argocd.argoproj.io/sync-options: Prune=confirm,Delete=confirm`. Without it, deleting or renaming `gitops/cluster/applications/flink-operator.yaml` is enough to lose the checkpoints: root prunes with `prune: true`, the Application's resources finalizer cascades into the namespace it explicitly manages, and `rook-ceph-bucket` reclaims with `Delete`, so the bucket goes with the claim. The namespace also holds FlinkDeployments owned by whoever runs the jobs, not by this repo.

With the option set, a sync that would prune one of these resources leaves the operation `Running` with `waiting for pruning confirmation of argoproj.io/Application/flink-operator` in `.status.operationState.message`. A cascading delete is blunter still: the controller refuses the whole cascade rather than skipping the guarded resource, so the Application sits with its deletion timestamp and finalizer in place and nothing under it is touched.

Approval is an `argocd.argoproj.io/deletion-approved` annotation on the *Application that manages the resource* — which here is not one Application but two. `root` manages `flink-operator.yaml`; `flink-operator` manages the namespace and the OBC. Tearing this down for real therefore takes two approvals, and they cannot both be given up front:

1. Drop `gitops/cluster/applications/flink-operator.yaml` and let root sync. It stops at the prune and waits.
2. Approve root, releasing it to delete the child Application:
   ```bash
   kubectl -n argocd annotate app root \
     argocd.argoproj.io/deletion-approved=$(date -u +%Y-%m-%dT%H:%M:%SZ) --overwrite
   ```
3. Wait for the child to actually enter deletion — the next timestamp has to be at or after this one:
   ```bash
   kubectl -n argocd get app flink-operator -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'
   ```
4. Approve `flink-operator`, releasing its finalizer to delete the namespace and the OBC:
   ```bash
   kubectl -n argocd annotate app flink-operator \
     argocd.argoproj.io/deletion-approved=$(date -u +%Y-%m-%dT%H:%M:%SZ) --overwrite
   ```

The order is load-bearing, because the value is compared against the operation it approves rather than merely checked for presence: a prune proceeds only if the timestamp is at or after the sync operation's `startedAt`, and a cascading delete only if it is at or after the Application's `deletionTimestamp`. Approving `flink-operator` before step 3 writes a timestamp that precedes the deletion timestamp it would have to cover, so it approves nothing and the teardown stalls with the app stuck `Terminating`; re-running step 4 clears it. Approving root before step 1 is stale the same way. The controller never removes the annotation, but for that same reason a leftover value cannot approve a later operation, so the guard re-arms itself. The UI's "Confirm Pruning" button and `argocd app confirm-deletion` write the same annotation with the current time and obey the same ordering.

## Writing a FlinkDeployment

Endpoint, path-style addressing, checkpoint/savepoint directories and Kubernetes HA are already set as operator defaults, so a job only has to load the S3 plugin and pick up the credentials:

```yaml
spec:
  image: flink:2.2.1
  flinkVersion: v2_2
  serviceAccount: flink
  podTemplate:
    spec:
      containers:
        - name: flink-main-container
          env:
            - name: ENABLE_BUILT_IN_PLUGINS
              value: flink-s3-fs-presto-2.2.1.jar
          envFrom:
            - secretRef:
                name: flink-checkpoints
```

The plugin jar name carries the image's own Flink version, so it moves with `image`. Operator 1.15 accepts `flinkVersion` up to `v2_2` — a newer image is rejected by the CRD's enum, not by a runtime error.

Checkpoints land at `s3p://flink-checkpoints/checkpoints/<job-id>/`, so one bucket is shared safely across jobs. `s3p://` is deliberate: presto registers both `s3` and `s3p`, and `flink-s3-fs-hadoop` registers both `s3` and `s3a`, so a job that loads both plugins would find two factories registered for `s3`. A `FileSink` to object storage needs the hadoop plugin as well — presto has no recoverable writer — and should address it as `s3a://`.

`state.checkpoints.dir` and `state.savepoints.dir` log a deprecation warning on Flink 2.x. That is expected; the replacement keys only exist from Flink 1.20 and would be silently ignored by an older job.

## Kafka

The homelab broker is `kafka-kafka-bootstrap.kafka.svc.cluster.local:9092`, plaintext, no `networkPolicyPeers` to open. It runs with `auto.create.topics.enable: false`, so a topic must be declared as a `KafkaTopic` CR in `gitops/platform/kafka/` before a job can produce to it — a typo surfaces as a failed fetch rather than a new single-partition topic.

## Metrics

The operator's own metrics are scraped from its pod (see the Flink operator block in `gitops/platform/alloy/values.yaml`). Job clusters are not covered: a `FlinkDeployment` exposes Prometheus metrics only if it sets `metrics.reporter.prom.*` in its own `flinkConfiguration`, and it needs its own Alloy block over the `flink` namespace.

## Exposing the JobManager UI

The UI is a plain HTTP service on port 8081. Route it like any other workload, pinning `sectionName: https` on the `parentRef` — the port-80 listener only redirects.
