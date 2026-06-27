# Prometheus Exporters (MySQL / HDFS / Trino) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Prometheus metrics coverage for MySQL (mysqld_exporter), HDFS namenode (jmx_exporter Java agent), and Trino coordinator+workers (jmx_exporter Java agent), all flowing into the existing Alloy → Mimir pipeline.

**Architecture:** Each component deploys its exporter close to the process (sidecar agent or dedicated exporter pod), exposes a metrics HTTP endpoint, and Alloy discovers it via `discovery.kubernetes` + `prometheus.scrape`. MySQL uses the `prometheus-community/prometheus-mysql-exporter` Helm chart; HDFS and Trino use the `bitnami/jmx-exporter` init-container pattern to inject the jmx_prometheus_javaagent JAR at pod startup.

**Tech Stack:** Kubernetes, Argo CD, Alloy (Grafana Agent Flow), Vault + ExternalSecrets, Helm, `bitnami/jmx-exporter:0.20.0`, `prometheus-community/prometheus-mysql-exporter:2.14.0`, `mysql:8`

## Global Constraints

- All YAML must pass `pre-commit run --all-files` before committing.
- ExternalSecrets use `vault-homelab` ClusterSecretStore, `creationPolicy: Owner`, sync-wave `-2`.
- Bootstrap Jobs use `argocd.argoproj.io/hook: Sync`, `BeforeHookCreation`, sync-wave `-1`, `backoffLimit: 10`, `restartPolicy: OnFailure`.
- No literal Secret manifests — all credentials via ExternalSecret.
- jmx_exporter agent listens on port `9087` for both HDFS and Trino.
- JMX agent JAR is staged to `/jmx/agent/` by an init container; rules config mounted at `/jmx/config.yaml`.

---

### Task 1: MySQL — Vault secret + ExternalSecrets + bootstrap Job

**Files:**
- Modify: `scripts/vault-secrets.template.yaml`
- Create: `gitops/workloads/helm/mysqld-exporter/extras/00-root-credentials.yaml`
- Create: `gitops/workloads/helm/mysqld-exporter/extras/01-bootstrap-job.yaml`
- Create: `gitops/workloads/helm/mysqld-exporter/extras/02-monitoring-credentials.yaml`

**Interfaces:**
- Produces: Vault path `homelab/mysql/monitoring` with keys `username=monitoring`, `password=<generated>`; secret `mysql-root` in `mysqld-exporter` ns with key `rootPassword`; secret `mysql-monitoring-credentials` in `mysqld-exporter` ns with keys `username`, `password`; MySQL user `monitoring@'%'` with `PROCESS, REPLICATION CLIENT, SELECT ON performance_schema.*`

- [ ] **Step 1: Add `mysql/monitoring` to vault template**

In `scripts/vault-secrets.template.yaml`, locate the `mysql/root` block and add the monitoring entry immediately after it:

```yaml
  - path: mysql/root
    fields: [password]
    values: { password: "" }

  - path: mysql/monitoring
    fields: [username, password]
    values: { username: monitoring, password: "" }
```

- [ ] **Step 2: Create `extras/00-root-credentials.yaml`**

Create `gitops/workloads/helm/mysqld-exporter/extras/00-root-credentials.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mysql-root
  namespace: mysqld-exporter
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-homelab
    kind: ClusterSecretStore
  target:
    name: mysql-root
    creationPolicy: Owner
    template:
      data:
        rootPassword: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef:
        key: mysql/root
        property: password
```

- [ ] **Step 3: Create `extras/01-bootstrap-job.yaml`**

Create `gitops/workloads/helm/mysqld-exporter/extras/01-bootstrap-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: mysql-monitoring-user-bootstrap
  namespace: mysqld-exporter
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"
spec:
  backoffLimit: 10
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mysql-bootstrap
          image: mysql:8
          env:
            - name: MYSQL_PWD
              valueFrom:
                secretKeyRef:
                  name: mysql-root
                  key: rootPassword
            - name: MONITORING_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-monitoring-credentials
                  key: password
          command: [bash, -ec]
          args:
            - |
              mysql -h mysql-cluster.mysql.svc -u root <<SQL
              CREATE USER IF NOT EXISTS 'monitoring'@'%' IDENTIFIED BY '${MONITORING_PASSWORD}';
              ALTER USER 'monitoring'@'%' IDENTIFIED BY '${MONITORING_PASSWORD}';
              GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'monitoring'@'%';
              GRANT SELECT ON performance_schema.* TO 'monitoring'@'%';
              FLUSH PRIVILEGES;
              SQL
```

- [ ] **Step 4: Create `extras/02-monitoring-credentials.yaml`**

Create `gitops/workloads/helm/mysqld-exporter/extras/02-monitoring-credentials.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mysql-monitoring-credentials
  namespace: mysqld-exporter
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-homelab
    kind: ClusterSecretStore
  target:
    name: mysql-monitoring-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: mysql/monitoring
        property: username
    - secretKey: password
      remoteRef:
        key: mysql/monitoring
        property: password
```

- [ ] **Step 5: Lint**

```bash
pre-commit run --all-files
```

Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/vault-secrets.template.yaml \
        gitops/workloads/helm/mysqld-exporter/extras/
git commit -m "feat(mysql): add vault secret and bootstrap job for monitoring user"
```

---

### Task 2: mysqld-exporter Helm workload + Alloy scrape

**Files:**
- Create: `gitops/workloads/helm/mysqld-exporter/config.json`
- Create: `gitops/workloads/helm/mysqld-exporter/values.yaml`
- Modify: `gitops/cluster/applications/workloads-helm.yaml`
- Modify: `gitops/platform/alloy/values.yaml`

**Interfaces:**
- Consumes: secret `mysql-monitoring-credentials` (from Task 1); MySQL user `monitoring@'%'` (from Task 1)
- Produces: Deployment `mysqld-exporter` in `mysqld-exporter` ns serving Prometheus metrics on port `9104`; Alloy scraping it with `job_name = "mysql"`

- [ ] **Step 1: Create `config.json`**

Create `gitops/workloads/helm/mysqld-exporter/config.json`:

```json
{
  "chart_repo": "https://prometheus-community.github.io/helm-charts",
  "chart_name": "prometheus-mysql-exporter",
  "chart_version": "2.14.0"
}
```

- [ ] **Step 2: Create `values.yaml`**

Create `gitops/workloads/helm/mysqld-exporter/values.yaml`:

```yaml
mysql:
  host: "mysql-cluster.mysql.svc"
  port: 3306
  user: "monitoring"
  pass: ""
  existingPasswordSecret:
    name: "mysql-monitoring-credentials"
    key: "password"
```

- [ ] **Step 3: Add workload to ApplicationSet**

In `gitops/cluster/applications/workloads-helm.yaml`, add `mysqld-exporter` to the list elements (after `trino`):

```yaml
                - name: trino
                - name: mysqld-exporter
```

- [ ] **Step 4: Add Alloy scrape block**

In `gitops/platform/alloy/values.yaml`, append inside the `content: |` block, immediately before the `controller:` key (after the last `prometheus.scrape "mimir_self"` block):

```
      // ── mysqld-exporter ───────────────────────────────────────────────────────

      discovery.kubernetes "mysqld_exporter" {
        role = "endpoints"
        namespaces {
          names = ["mysqld-exporter"]
        }
        selectors {
          role  = "endpoints"
          label = "app.kubernetes.io/name=prometheus-mysql-exporter"
        }
      }

      discovery.relabel "mysqld_exporter" {
        targets = discovery.kubernetes.mysqld_exporter.targets
        rule {
          source_labels = ["__meta_kubernetes_endpoint_port_name"]
          regex         = "mysql-exporter"
          action        = "keep"
        }
      }

      prometheus.scrape "mysql" {
        targets    = discovery.relabel.mysqld_exporter.output
        job_name   = "mysql"
        forward_to = [prometheus.remote_write.mimir.receiver]
      }
```

- [ ] **Step 5: Lint**

```bash
pre-commit run --all-files
```

Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
git add gitops/workloads/helm/mysqld-exporter/config.json \
        gitops/workloads/helm/mysqld-exporter/values.yaml \
        gitops/cluster/applications/workloads-helm.yaml \
        gitops/platform/alloy/values.yaml
git commit -m "feat(mysql): add mysqld-exporter workload and Alloy scrape"
```

- [ ] **Step 7: Seed Vault and verify cluster**

On a machine with `VAULT_ADDR` and `VAULT_TOKEN` set:

```bash
scripts/seed-vault.sh
```

Expected output contains:
```
>>> Writing homelab/mysql/monitoring
```

After Argo CD syncs, verify:

```bash
# Bootstrap Job completed successfully
kubectl -n mysqld-exporter get job mysql-monitoring-user-bootstrap

# Exporter pod is running
kubectl -n mysqld-exporter get pods

# Metrics endpoint responds
kubectl -n mysqld-exporter port-forward svc/mysqld-exporter-prometheus-mysql-exporter 9104:9104 &
curl -s http://localhost:9104/metrics | grep mysql_up
# Expected: mysql_up 1
```

---

### Task 3: HDFS namenode JMX agent + Alloy scrape

**Files:**
- Modify: `gitops/workloads/raw/hdfs/manifests/hdfs.yaml`
- Modify: `gitops/platform/alloy/values.yaml`

**Interfaces:**
- Produces: namenode pod serving jmx_exporter metrics on port `9087`; Alloy scraping it with `job_name = "hdfs"`

- [ ] **Step 1: Add `hdfs-jmx-config` ConfigMap to `hdfs.yaml`**

At the top of `gitops/workloads/raw/hdfs/manifests/hdfs.yaml` (before the existing `hdfs-config` ConfigMap), add:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hdfs-jmx-config
  namespace: hdfs
data:
  config.yaml: |
    startDelaySeconds: 0
    ssl: false
    rules:
      - pattern: "Hadoop<service=NameNode, name=(.+)><>(.+)"
        name: "hadoop_namenode_$1_$2"
        labels:
          service: namenode
      - pattern: ".*"
---
```

- [ ] **Step 2: Add init container, volumes, env, and port to namenode StatefulSet**

In the namenode StatefulSet spec, make the following additions. The final `spec.template.spec` section should look like this (additions marked with comments):

```yaml
      # NEW: init container stages the JMX agent JAR into a shared emptyDir
      initContainers:
        - name: volume-permissions
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /hadoop/dfs/name && chown -R 1000:1000 /hadoop/dfs/name"]
          securityContext:
            runAsUser: 0
            runAsNonRoot: false
          volumeMounts:
            - { name: data, mountPath: /hadoop/dfs/name }
        - name: jmx-exporter-init
          image: bitnami/jmx-exporter:0.20.0
          command: ["cp", "/opt/bitnami/jmx-exporter/jmx_prometheus_javaagent.jar", "/jmx/agent/"]
          volumeMounts:
            - { name: jmx-agent, mountPath: /jmx/agent }
      containers:
        - name: namenode
          image: apache/hadoop:3.4.0
          command: ["/bin/bash", "-ec"]
          args:
            - |
              if [ ! -f /hadoop/dfs/name/current/VERSION ]; then
                rm -rf /hadoop/dfs/name/* /hadoop/dfs/name/.??*
                /opt/hadoop/bin/hdfs namenode -format -nonInteractive
              fi
              exec /opt/hadoop/bin/hdfs namenode
          # NEW: agent flag appended to namenode JVM options
          env:
            - name: HADOOP_NAMENODE_OPTS
              value: "-javaagent:/jmx/agent/jmx_prometheus_javaagent.jar=9087:/jmx/config.yaml"
          ports:
            - { name: rpc, containerPort: 8020 }
            - { name: ui,  containerPort: 9870 }
            - { name: jmx, containerPort: 9087 }   # NEW
          volumeMounts:
            - { name: data,       mountPath: /hadoop/dfs/name }
            - { name: config,     mountPath: /opt/hadoop/etc/hadoop }
            - { name: jmx-agent,  mountPath: /jmx/agent }               # NEW
            - name: jmx-config                                           # NEW
              mountPath: /jmx/config.yaml
              subPath: config.yaml
      volumes:
        - name: config
          configMap: { name: hdfs-config }
        - name: jmx-agent                                                # NEW
          emptyDir: {}
        - name: jmx-config                                               # NEW
          configMap: { name: hdfs-jmx-config }
```

- [ ] **Step 3: Add `jmx` port to namenode Service**

In the namenode Service spec, add the jmx port:

```yaml
spec:
  selector: { app.kubernetes.io/name: namenode }
  ports:
    - { name: rpc, port: 8020, targetPort: rpc }
    - { name: ui,  port: 9870, targetPort: ui  }
    - { name: jmx, port: 9087, targetPort: jmx }   # NEW
```

- [ ] **Step 4: Add Alloy scrape block**

In `gitops/platform/alloy/values.yaml`, append after the `prometheus.scrape "mysql"` block from Task 2:

```
      // ── HDFS namenode ─────────────────────────────────────────────────────────

      discovery.kubernetes "hdfs" {
        role = "endpoints"
        namespaces {
          names = ["hdfs"]
        }
        selectors {
          role  = "endpoints"
          label = "app.kubernetes.io/name=namenode"
        }
      }

      discovery.relabel "hdfs" {
        targets = discovery.kubernetes.hdfs.targets
        rule {
          source_labels = ["__meta_kubernetes_endpoint_port_name"]
          regex         = "jmx"
          action        = "keep"
        }
      }

      prometheus.scrape "hdfs" {
        targets    = discovery.relabel.hdfs.output
        job_name   = "hdfs"
        forward_to = [prometheus.remote_write.mimir.receiver]
      }
```

- [ ] **Step 5: Lint**

```bash
pre-commit run --all-files
```

Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
git add gitops/workloads/raw/hdfs/manifests/hdfs.yaml \
        gitops/platform/alloy/values.yaml
git commit -m "feat(hdfs): add jmx_exporter agent to namenode and Alloy scrape"
```

- [ ] **Step 7: Verify on cluster**

After Argo CD syncs the `hdfs` and `alloy` apps:

```bash
# Namenode pod restarts and comes up with both init containers
kubectl -n hdfs get pods -w
# Expected: namenode-0 with READY 1/1 after init containers complete

# JMX metrics endpoint responds
kubectl -n hdfs port-forward svc/namenode 9087:9087 &
curl -s http://localhost:9087/metrics | grep hadoop_namenode
# Expected: lines like hadoop_namenode_FSNamesystem_CapacityTotal ...
```

---

### Task 4: Trino JMX agent + Alloy scrape

**Files:**
- Create: `gitops/workloads/helm/trino/extras/jmx-config.yaml`
- Modify: `gitops/workloads/helm/trino/values.yaml`
- Modify: `gitops/platform/alloy/values.yaml`

**Interfaces:**
- Produces: Trino coordinator and worker pods each serving jmx_exporter metrics on port `9087`; Alloy scraping them with `job_name = "trino"`

- [ ] **Step 1: Create `extras/jmx-config.yaml`**

Create `gitops/workloads/helm/trino/extras/jmx-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-jmx-config
  namespace: trino
data:
  config.yaml: |
    startDelaySeconds: 0
    ssl: false
    rules:
      - pattern: "trino.execution<name=QueryManager><>(.+)"
        name: "trino_query_manager_$1"
      - pattern: "trino.execution<name=TaskManager><>(.+)"
        name: "trino_task_manager_$1"
      - pattern: "trino.memory<name=ClusterMemoryManager><>(.+)"
        name: "trino_cluster_memory_$1"
      - pattern: "trino.failuredetector<name=HeartbeatFailureDetector><>(.+)"
        name: "trino_failure_detector_$1"
      - pattern: ".*"
```

- [ ] **Step 2: Update `trino/values.yaml` with JMX agent config**

`gitops/workloads/helm/trino/values.yaml` has existing `coordinator:` and `worker:` top-level keys. Make three changes:

**2a — Append `initContainers:` as a new top-level key at the end of the file:**

```yaml

# JMX exporter agent — copies JAR to shared emptyDir before Trino starts.
initContainers:
  coordinator:
    - name: jmx-exporter-init
      image: bitnami/jmx-exporter:0.20.0
      command: ["cp", "/opt/bitnami/jmx-exporter/jmx_prometheus_javaagent.jar", "/jmx/agent/"]
      volumeMounts:
        - name: jmx-agent
          mountPath: /jmx/agent
  worker:
    - name: jmx-exporter-init
      image: bitnami/jmx-exporter:0.20.0
      command: ["cp", "/opt/bitnami/jmx-exporter/jmx_prometheus_javaagent.jar", "/jmx/agent/"]
      volumeMounts:
        - name: jmx-agent
          mountPath: /jmx/agent
```

**2b — Edit the existing `coordinator:` block in-place to add JMX keys.** The final coordinator block must be:

```yaml
coordinator:
  jvm:
    maxHeapSize: "1500M"
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
  additionalJVMConfig:
    - "-javaagent:/jmx/agent/jmx_prometheus_javaagent.jar=9087:/jmx/config.yaml"
  additionalExposedPorts:
    jmx:
      internalPort: 9087
      port: 9087
      protocol: TCP
  additionalVolumes:
    - name: jmx-agent
      emptyDir: {}
    - name: jmx-config
      configMap:
        name: trino-jmx-config
  additionalVolumeMounts:
    - name: jmx-agent
      mountPath: /jmx/agent
    - name: jmx-config
      mountPath: /jmx/config.yaml
      subPath: config.yaml
```

**2c — Edit the existing `worker:` block in-place to add JMX keys.** The final worker block must be:

```yaml
worker:
  replicas: 2
  jvm:
    maxHeapSize: "3G"
  resources:
    requests:
      cpu: 1
      memory: 4Gi
  additionalJVMConfig:
    - "-javaagent:/jmx/agent/jmx_prometheus_javaagent.jar=9087:/jmx/config.yaml"
  additionalExposedPorts:
    jmx:
      internalPort: 9087
      port: 9087
      protocol: TCP
  additionalVolumes:
    - name: jmx-agent
      emptyDir: {}
    - name: jmx-config
      configMap:
        name: trino-jmx-config
  additionalVolumeMounts:
    - name: jmx-agent
      mountPath: /jmx/agent
    - name: jmx-config
      mountPath: /jmx/config.yaml
      subPath: config.yaml
```

- [ ] **Step 3: Add Alloy scrape block**

In `gitops/platform/alloy/values.yaml`, append after the `prometheus.scrape "hdfs"` block from Task 3:

```
      // ── Trino ─────────────────────────────────────────────────────────────────

      discovery.kubernetes "trino_jmx" {
        role = "endpoints"
        namespaces {
          names = ["trino"]
        }
        selectors {
          role  = "endpoints"
          label = "app.kubernetes.io/name=trino"
        }
      }

      discovery.relabel "trino_jmx" {
        targets = discovery.kubernetes.trino_jmx.targets
        rule {
          source_labels = ["__meta_kubernetes_endpoint_port_name"]
          regex         = "jmx"
          action        = "keep"
        }
      }

      prometheus.scrape "trino" {
        targets    = discovery.relabel.trino_jmx.output
        job_name   = "trino"
        forward_to = [prometheus.remote_write.mimir.receiver]
      }
```

- [ ] **Step 4: Lint**

```bash
pre-commit run --all-files
```

Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add gitops/workloads/helm/trino/extras/jmx-config.yaml \
        gitops/workloads/helm/trino/values.yaml \
        gitops/platform/alloy/values.yaml
git commit -m "feat(trino): add jmx_exporter agent to coordinator/workers and Alloy scrape"
```

- [ ] **Step 6: Verify on cluster**

After Argo CD syncs the `trino` and `alloy` apps:

```bash
# Trino coordinator pod comes up with init container
kubectl -n trino get pods -w
# Expected: trino-coordinator-... READY 1/1 after jmx-exporter-init completes

# JMX metrics from coordinator
kubectl -n trino port-forward svc/trino 9087:9087 &
curl -s http://localhost:9087/metrics | grep trino_query_manager
# Expected: lines like trino_query_manager_RunningQueries 0.0 ...

# Confirm metrics flowing to Mimir (Alloy logs)
kubectl -n alloy logs -l app.kubernetes.io/name=alloy --tail=20 | grep trino
```
