<div align="center">

# RedisForge

**Production-grade Redis 8.2 cluster automation with Envoy, TLS, and ruthless operational discipline.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Redis](https://img.shields.io/badge/Redis-8.2-red.svg)](https://redis.io/)
[![Envoy](https://img.shields.io/badge/Envoy-v1.32-blue.svg)](https://www.envoyproxy.io/)
[![Docker](https://img.shields.io/badge/Docker-20.10+-2496ED.svg?logo=docker&logoColor=white)](https://www.docker.com/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/siyamsarker/RedisForge/pulls)

</div>

---

## Table of Contents

1. [Purpose & How It Works](#purpose--how-it-works)
2. [System Architecture](#system-architecture)
3. [Redis Cluster Deep-Dive](#redis-cluster-deep-dive)
4. [Auto-Failover & Persistence](#auto-failover--persistence-flow)
5. [Production Deployment Guide](#production-deployment-guide)
6. [Script Catalog & Usage](#script-catalog--usage)
7. [Monitoring & Observability](#monitoring--observability)
8. [Operations & Runbooks](#operations--runbooks)
9. [Troubleshooting Playbook](#troubleshooting-playbook)
10. [Integration Testing](#integration-testing)
11. [Repository Layout](#repository-layout)
12. [Contributing](#contributing) · [License](#license) · [Support](#support)

---

## Purpose & How It Works

| Goal | Reality check |
|------|---------------|
| Provide a single, TLS-terminated Redis endpoint that hides all cluster complexity from applications. | Envoy’s `redis_proxy` terminates TLS, enforces ACL auth, understands cluster slots, and retries transparently. |
| Ship hardened Redis nodes with AOF durability and battle-tested defaults. | Custom Redis image + config templates enforce ACLs, persistence, and high file descriptor limits. |
| Offer ruthless operational automation. | Scripts bootstrap hosts, initialize clusters, scale slots, rotate logs, take backups, and simulate chaos. |
| Avoid “black box” magic. | Everything is plain Docker + Bash. You get auditable configs, no proprietary agents, and zero vendor lock-in. |

**Flow summary**
1. **Envoy node** exposes `:6379` (or `:6380` TLS) as the only endpoint apps ever see.
2. **Three Redis masters** own the 16,384 cluster slots; each master has at least one replica in another AZ.
3. **Cluster metadata** (slots + node health) is polled by Envoy every 10s, so applications don’t chase redirects.
4. **Persistence** uses AOF (`appendfsync everysec`) with S3-backed snapshots.
5. **Monitoring hooks** (redis_exporter, node_exporter, Envoy metrics) feed your existing Prometheus + Grafana.

---

## System Architecture

```mermaid
flowchart LR
    subgraph Clients
        A[Apps / Services]
    end
    subgraph Proxy
        B[Envoy redis_proxy<br/>TLS termination + ACL auth]
    end
    subgraph RedisCluster["Redis Cluster\n(3 masters + replicas)"]
        C1[Master A<br/>slots 0-5460]
        C2[Master B<br/>slots 5461-10922]
        C3[Master C<br/>slots 10923-16383]
        R1[Replica A']
        R2[Replica B']
        R3[Replica C']
    end
    subgraph Observability
        P1[redis_exporter<br/>9121]
        P2[node_exporter<br/>9100]
        P3[Envoy /stats<br/>9901]
        Grafana[(Grafana)]
        Prometheus[(Prometheus)]
    end

    A -->|TLS| B
    B -->|slot-aware TCP| C1
    B -->|slot-aware TCP| C2
    B -->|slot-aware TCP| C3
    C1 --> R1
    C2 --> R2
    C3 --> R3

    P1 --> Prometheus
    P2 --> Prometheus
    P3 --> Prometheus
    Prometheus --> Grafana
```

**Key traits**
- Only Envoy is internet/ELB facing. Redis nodes stay in private subnets.
- Envoy holds a connection pool per master, retries failed ops, and evenly balances keys via Maglev hashing.
- You run redis_exporter + node_exporter locally (per node) and scrape Envoy’s `/stats/prometheus`; Prometheus pulls everything over private IPs.

---

## Redis Cluster Deep-Dive

```mermaid
graph TB
    subgraph AZ-a
        M1[(Master A)]
        R1[(Replica A')]
    end
    subgraph AZ-b
        M2[(Master B)]
        R2[(Replica B')]
    end
    subgraph AZ-c
        M3[(Master C)]
        R3[(Replica C')]
    end

    M1 -- cluster bus 16379 --> M2
    M2 -- cluster bus 16379 --> M3
    M3 -- cluster bus 16379 --> M1

    M1 -- async repl --> R1
    M2 -- async repl --> R2
    M3 -- async repl --> R3

    Envoy[
      Envoy redis_proxy
      - cluster refresh 10s
      - downstream ACL auth
      - upstream TLS
      - request retries
    ]
    Envoy --> M1
    Envoy --> M2
    Envoy --> M3
```

**Cluster mechanics**
- Slot map: 0-16383 split evenly across the three masters. Cluster metadata stored in `nodes.conf` and polled by Envoy.
- Replication: asynchronous, TLS-enabled, uses dedicated ACL user to keep secrets scoped.
- Health: `cluster-node-timeout` = 5s; nodes mark peers down fast, so failover finishes in ~10-15 seconds.
- Sentinel: optional; Redis native cluster failover already covers master promotion, but Sentinel can be layered on if you want deterministic quorum voting.

---

## Auto-Failover & Persistence Flow

| Risk | Mitigation inside RedisForge |
|------|-------------------------------|
| Master dies (hardware/OS fault) | Redis cluster flags it failing, promotes replica within the same slot range. Envoy refreshes topology every 10s and drops dead upstream connections automatically. |
| Envoy sees stale topology | `cluster_refresh_rate` + redirect refresh handles MOVED/ASK replies immediately. |
| Data loss | AOF (`appendonly yes`, `appendfsync everysec`) + S3 archive via `backup.sh`. Optional mixed mode (`aof-use-rdb-preamble yes`) keeps restart time low. |
| Replica lag spikes | Grafana board surfaces `redis_replication_lag_seconds`; run `scripts/scale.sh add` to add replicas in overloaded AZs. |

```mermaid
sequenceDiagram
    participant Client
    participant Envoy
    participant MasterA
    participant ReplicaA
    participant S3

    Client->>Envoy: SET key:value
    Envoy->>MasterA: Write (slot 1024)
    MasterA-->>ReplicaA: Async replicate (AOF)
    MasterA-->>S3: (via backup.sh) Upload tarred AOF hourly

    Note over MasterA,ReplicaA: Master failure
    ReplicaA->>ReplicaA: Promote to Master (cluster failover)
    Envoy->>ReplicaA: Rebuild pool after refresh
    Client->>Envoy: Subsequent GET routed to new Master
```

### What you must do
- **Do not** run replicas on the same hypervisor. Spread masters and replicas across three AZs minimum.
- Run `backup.sh` via cron w/ IAM role that can write to S3 (or equivalent object store).
- Periodically rehearse failover: `./scripts/scale.sh remove <node>` combined with chaos tooling.

---

## Production Deployment Guide

> If you skip any of this, you’re gambling your data. Follow it step-by-step.

### 1. Design the topology
| Component | Count | Instance type | Ports | Notes |
|-----------|-------|---------------|-------|-------|
| Envoy proxy | 1 (per cluster endpoint) | c6i.large (min) | 6379/6380, 9901 | Attach public/ELB if needed; lock admin port to Prometheus CIDRs only. |
| Redis masters | 3 | r6i.2xlarge (baseline) | 6379, 16379 | Pin each to a different AZ; enable EBS gp3/ io2. |
| Redis replicas | 3 | r6i.xlarge | 6379, 16379 | Co-locate with opposite masters (A→B, etc.) or standalone nodes. |

### 2. Prepare the OS
```bash
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w vm.overcommit_memory=1
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
sudo tee -a /etc/security/limits.conf <<'EOF'
* soft nofile 100000
* hard nofile 100000
EOF
```

### 3. Bootstrap each node
```bash
sudo yum install -y docker git jq redis
sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker
git clone https://github.com/siyamsarker/RedisForge.git
cd RedisForge && cp env.example .env
```

Populate `.env` with:
- `REDIS_REQUIREPASS`, `REDIS_ACL_PASS`, `REDIS_READONLY_PASS`, etc. (use `openssl rand -base64 32`)
- `REDIS_CLUSTER_ANNOUNCE_IP=<this node private IP>`
- `REDIS_MASTER_{1..3}_HOST` (private DNS / IPs for Envoy)
- `BACKUP_S3_BUCKET`, `AWS_REGION`

### 4. Deploy Redis nodes (run on each master/replica host)
```bash
./scripts/deploy.sh redis
docker logs -f redis-master
```

### 5. Initialize the cluster (run once from any node with `redis-cli`)
```bash
REDIS_REQUIREPASS=$REDIS_REQUIREPASS \
./scripts/init-cluster.sh \
"10.0.1.10:6379,10.0.2.11:6379,10.0.3.12:6379,10.0.4.10:6379,10.0.5.11:6379,10.0.6.12:6379"
```

Verify:
```bash
redis-cli -h 10.0.1.10 -a "$REDIS_REQUIREPASS" cluster info
redis-cli -h 10.0.1.10 -a "$REDIS_REQUIREPASS" cluster slots
```

### 6. Deploy Envoy proxy node
```bash
./scripts/generate-certs.sh config/tls/prod
./scripts/deploy.sh envoy
curl -k https://<envoy-ip>:6379 -u app_user:$REDIS_ACL_PASS ping
```

### 7. Wire monitoring + backups
- Run `./scripts/setup-exporters.sh` on every Redis host.
- Schedule `backup.sh` + `log-rotate.sh` via cron (see [Operations](#operations--runbooks)).
- Import Grafana dashboard JSON and create Prometheus alerts.

---

## Script Catalog & Usage

| Script | When to run | What it does | Example |
|--------|-------------|--------------|---------|
| `scripts/deploy.sh redis|envoy|monitoring` | Bootstrapping or rebuilding a node | Builds Docker images, validates TLS secrets, runs containers with health checks. | `sudo ./scripts/deploy.sh redis` |
| `scripts/init-cluster.sh <nodes>` | After all nodes are up | Creates the Redis cluster, pairs masters with replicas, validates state. | `./scripts/init-cluster.sh "host1:6379,...,host6:6379"` |
| `scripts/scale.sh add|remove` | Adding masters/replicas or decommissioning | Adds nodes, rebalances slots, or drains/removes nodes safely. | `./scripts/scale.sh add 10.0.4.15:6379 --role replica --replica-of <master-id>` |
| `scripts/backup.sh` | Hourly via cron | Archives the newest AOF + `nodes.conf` and uploads to S3. | `BACKUP_S3_BUCKET=s3://prod-redis ./scripts/backup.sh` |
| `scripts/log-rotate.sh <dir> <sizeMB> <count>` | Daily via cron | Rotates Redis logs, compresses old copies, enforces retention. | `./scripts/log-rotate.sh /var/log/redis 1024 7` |
| `scripts/test-cluster.sh <host> <port>` | Smoke tests after deploy or failover | Runs PING, SET/GET, pub/sub, cluster info checks through Envoy. | `./scripts/test-cluster.sh envoy.company.local 6379` |
| `scripts/setup-exporters.sh` | After Redis deploy on every node | Launches redis_exporter + node_exporter via Docker (host networking). | `./scripts/setup-exporters.sh` |
| `tests/run-integration.sh` | In CI or before large changes | Spins up full cluster in Docker Compose, initializes slots, runs tests. | `./tests/run-integration.sh` |
| `scripts/generate-certs.sh <dir>` | Rotating TLS certs | Issues self-signed certs for lower envs; replace with CA certs in prod. | `./scripts/generate-certs.sh config/tls/prod` |

If you don’t know **exactly** why you are running a script, stop. Blind automation is how you lose data.

---

## Monitoring & Observability

1. **Exporters**
   ```bash
   ./scripts/setup-exporters.sh
   curl http://localhost:9121/metrics | head
   curl http://localhost:9100/metrics | head
   ```
2. **Prometheus scrape snippets**
   ```yaml
   - job_name: 'redisforge-redis'
     static_configs:
       - targets: ['10.0.1.10:9121','10.0.2.11:9121','10.0.3.12:9121']
   - job_name: 'redisforge-envoy'
     metrics_path: /stats/prometheus
     static_configs:
       - targets: ['envoy-vpc.internal:9901']
   ```
3. **Grafana** – import `monitoring/grafana/dashboards/redisforge-dashboard.json`.
4. **Alerting** – adapt `monitoring/alertmanager/alertmanager.yaml`; wire to PagerDuty/Slack.

Key metrics to never ignore:
- `redis_cluster_slots_ok` (<16384 = fire drill)
- `redis_connected_slaves` (should match replica targets)
- `redis_aof_current_size_bytes` vs disk usage
- `envoy_cluster_upstream_rq_xx{response_code_class="5"}`

---

## Operations & Runbooks

### Scaling
```bash
# Add an additional master (rebalances slots)
REDIS_REQUIREPASS=$PASS ./scripts/scale.sh add 10.0.7.10:6379 --role master

# Add replica pinned to master ID
REDIS_REQUIREPASS=$PASS ./scripts/scale.sh add 10.0.8.11:6379 --role replica --replica-of <master-node-id>

# Remove node after draining slots
REDIS_REQUIREPASS=$PASS ./scripts/scale.sh remove <node-id>
```

### Backups & retention
```bash
BACKUP_S3_BUCKET=s3://prod-redisforge ./scripts/backup.sh
# Cron: 0 * * * * /opt/RedisForge/scripts/backup.sh >> /var/log/redisforge-backup.log 2>&1
```

### Log rotation
```bash
./scripts/log-rotate.sh /var/log/redis 1024 7
# Cron: 0 2 * * * /opt/RedisForge/scripts/log-rotate.sh /var/log/redis 1024 7
```

### TLS rotation
```bash
./scripts/generate-certs.sh config/tls/prod
rsync config/tls/prod/* envoy-host:/etc/envoy/certs
docker restart envoy-proxy
```

### Health spot-checks
```bash
redis-cli -h envoy.company.local -p 6379 --tls --cacert config/tls/prod/ca.crt -a "$REDIS_REQUIREPASS" ping
curl -s https://envoy.company.local:9901/stats/prometheus | grep envoy_cluster_upstream_rq_time_bucket | head
```

---

## Troubleshooting Playbook

| Symptom | Quick triage | Root fix |
|---------|--------------|----------|
| `redis-cli` through Envoy returns `MOVED` constantly | Envoy can’t refresh topology (wrong Redis auth or TLS). Check Envoy logs + `/clusters`. | Ensure `REDIS_REQUIREPASS` matches across Redis + Envoy env vars; verify `/etc/envoy/certs`. |
| Slots `<16384` or `cluster_state:fail` | `redis-cli --cluster check <node>` | Replace failed nodes, run `./scripts/scale.sh remove <dead-node-id>`, then add new replica. |
| Backups missing in S3 | Check `/var/log/redisforge-backup.log` and IAM role permissions. | Attach IAM policy for `s3:PutObject`, ensure `BACKUP_S3_BUCKET` is set, and rerun `backup.sh`. |
| High replication lag | `redis-cli info replication | grep lag` | Investigate network saturation, add replicas, or reshard heavy slots off overloaded master. |
| Envoy admin port inaccessible | Security group or firewalls blocking 9901. | Allow Prometheus CIDRs; never expose 9901 publicly. |
| Containers crash-loop | `docker logs redis-master` or `docker logs envoy-proxy` | Usually missing secrets or wrong env vars. Re-create `.env`, redeploy with correct TLS paths. |

**Golden rule:** never restart everything at once. Fix one component, validate, then move on. Chaos is contagious.

---

## Integration Testing

```bash
./scripts/generate-certs.sh config/tls/dev
./tests/run-integration.sh
```

What it does:
1. Builds Redis + Envoy images.
2. Spins up 3 masters + 3 replicas + Envoy via Docker Compose.
3. Runs `init-cluster.sh` and `test-cluster.sh`.
4. Tears everything down so your workstation isn’t polluted.

If this fails locally, **do not** deploy to production. Fix the tests first.

---

## Repository Layout

```
RedisForge/
├── config/                    # Envoy + Redis templates, TLS helper docs
├── docker/                    # Hardened Dockerfiles + entrypoints
├── docs/quickstart.md         # Extended deployment walkthrough
├── monitoring/                # Alertmanager + Grafana assets
├── scripts/                   # Automation (deploy, scale, backup, etc.)
├── tests/                     # Integration harness
├── env.example
├── LICENSE
└── README.md
```

---

## Contributing

1. Fork the repo, branch off `main`.
2. Make your changes + update docs.
3. Run `./tests/run-integration.sh` (or your CI equivalent).
4. Open a PR with logs/screenshots. No tests = no merge.

Keep scripts idempotent, don’t hardcode secrets, and document every operational change.

---

## License

RedisForge is distributed under the [MIT License](./LICENSE).

---

## Support

- Issues & ideas: [GitHub Issues](https://github.com/your-org/RedisForge/issues)
- Discussions & design questions: open a Discussion or PR.
- Security disclosures: contact the maintainers privately.

Built for operators who refuse to trust luck more than discipline.
