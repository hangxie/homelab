# Spark

This workload installs the Kubeflow Spark Operator chart and watches
`SparkApplication` resources in the `spark` namespace. There is no
long-lived Spark master/worker cluster; workers are executor pods created per
Spark job.

Use the official Apache Spark image as the default worker/executor source:

```yaml
spec:
  image: docker.io/library/spark:4.1.2
  sparkVersion: 4.1.2
```

## S3 access

Jobs that read or write Ceph RGW through `s3a://` carry the S3A settings in `sparkConf`, plus credentials for the RGW user that owns the bucket.

```yaml
spec:
  sparkConf:
    spark.hadoop.fs.s3a.endpoint: http://rook-ceph-rgw-object-store.rook-ceph.svc/
    spark.hadoop.fs.s3a.endpoint.region: us-east-1
    spark.hadoop.fs.s3a.path.style.access: "true"
    spark.hadoop.fs.s3a.connection.ssl.enabled: "false"
    spark.hadoop.fs.s3a.aws.credentials.provider: software.amazon.awssdk.auth.credentials.EnvironmentVariableCredentialsProvider
  driver:
    serviceAccount: spark
    envFrom:
      - secretRef: { name: spark-s3 }
  executor:
    envFrom:
      - secretRef: { name: spark-s3 }
```

Do not reach for `spec.sparkConfigMap: spark-defaults` in place of that block. It mounts, but delivers none of these settings — see the next section. The `spark-defaults` ConfigMap also still names the AWS SDK v1 credential provider class, which predates the SDK v2 move in hadoop-aws 3.4.x, so copying its value verbatim is not right either.

None of it loads unless the image has Hadoop S3A support (`hadoop-aws` plus the matching AWS SDK) — bake that into a derived image or pull it in through the job's `spec.deps.packages`.

`spark-s3` covers the job's own buckets. Warehouse tables need a different RGW user; see [Hive metastore](#hive-metastore).

## `sparkConfigMap` does not reach the Hadoop configuration

`spec.sparkConfigMap: spark-defaults` mounts the ConfigMap, but none of its `spark.hadoop.fs.s3a.*` settings arrive in the driver's Hadoop configuration — a driver dumping them reports `fs.s3a.endpoint = None`, `path.style.access = false`, `connection.ssl.enabled = true`, while entries passed through `sparkConf` in the same job are present. The driver pod ends up with `SPARK_CONF_DIR` set twice, `/opt/spark/conf` (spark-submit's generated properties) and `/etc/spark/conf` (this ConfigMap), and the two shadow each other.

With no endpoint, S3A signs for real AWS S3 and every bucket read fails `AccessDeniedException ... Status Code: 403`. It is also why `spark.eventLog.dir` has never written an object to `s3a://spark-logs/`.

## Hive metastore

Reaching the metastore takes more than the thrift URI, because Spark's built-in Hive client is 2.3.10 and a Hive 4 metastore answers it with `Invalid method name: 'get_table'`.

```yaml
spec:
  sparkConf:
    spark.sql.catalogImplementation: hive
    spark.hadoop.hive.metastore.uris: thrift://hive-metastore.hive.svc:9083
    # Spark 4.1 accepts 4.0.0-4.1.0 here; a 4.1.0 client drives the 4.2.x
    # server fine. `maven` resolves the client jars at driver start, which
    # adds a few minutes to the first query.
    spark.sql.hive.metastore.version: "4.1.0"
    spark.sql.hive.metastore.jars: maven
    # That resolution runs Ivy inside the driver JVM, which writes under
    # `user.home`. The image's uid has no home directory, so Ivy fails on
    # /nonexistent. Setting HOME is not enough — the JVM reads user.home from
    # the passwd entry, not the environment.
    spark.driver.extraJavaOptions: -Duser.home=/tmp
  driver:
    envFrom:
      # Not spark-s3: the warehouse bucket belongs to the `hive` RGW user and
      # RGW denies cross-user access.
      - secretRef: { name: hive-s3 }
  executor:
    envFrom:
      - secretRef: { name: hive-s3 }
```

These go on top of the S3 block above, with `hive-s3` swapped in for `spark-s3` in both `envFrom` lists. Jobs that only touch their own buckets (`s3a://spark-logs/`, scratch data) keep `spark-s3`.

This workload does not have a HuggingFace download path. The homelab HF token
requirement remains in the model-serving workloads that pull from
HuggingFace.
