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

Jobs that read or write Ceph RGW through `s3a://` should also opt in to the
homelab defaults and credentials:

```yaml
spec:
  sparkConfigMap: spark-defaults
  driver:
    serviceAccount: spark
    envFrom:
      - secretRef:
          name: spark-s3
  executor:
    envFrom:
      - secretRef:
          name: spark-s3
```

`spark-defaults` preserves the Rook/Ceph S3A endpoint, path-style access, and
environment-variable credential provider. The Spark image still needs Hadoop
S3A support (`hadoop-aws` plus matching AWS SDK dependencies) for real S3A
jobs; bake those into a derived image or add them through the job's
`spec.deps.packages`.

If a job needs the shared Hive metastore used by Trino, add the metastore URI
in the job's Spark config:

```yaml
spec:
  sparkConf:
    spark.sql.catalogImplementation: hive
    spark.hadoop.hive.metastore.uris: thrift://hive-metastore.hive.svc:9083
```

This workload does not have a HuggingFace download path. The homelab HF token
requirement remains in the model-serving workloads that pull from
HuggingFace.
