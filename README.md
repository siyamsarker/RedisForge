<div align="center">

# RedisForge

**Production-grade Redis 8.2 cluster automation with Envoy proxy, TLS, and observability hooks.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Redis](https://img.shields.io/badge/Redis-8.2-red.svg)](https://redis.io/)
[![Envoy](https://img.shields.io/badge/Envoy-v1.32-blue.svg)](https://www.envoyproxy.io/)
[![Docker](https://img.shields.io/badge/Docker-20.10+-2496ED.svg?logo=docker&logoColor=white)](https://www.docker.com/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/siyamsarker/RedisForge/pulls)

</div>

---

## Table of Contents

1. [Overview](#overview)
2. [Why RedisForge](#why-redisforge)
3. [Architecture](#architecture)
4. [Requirements](#requirements)
5. [Deployment Workflow](#deployment-workflow)
6. [Monitoring Integration](#monitoring-integration)
7. [Operations & Runbooks](#operations--runbooks)
8. [Integration Testing](#integration-testing)
9. [Repository Layout](#repository-layout)
10. [Contributing](#contributing)
11. [License](#license)
12. [Support](#support)

---

## Overview

RedisForge condenses everything needed to operate a resilient Redis OSS cluster into Docker images, declarative templates, and idempotent runbooks. It **does not** provision EC2 instances, Prometheus, Alertmanager, or Grafana—you plug RedisForge into infrastructure you already manage.

What you get:
- Single TLS endpoint via Envoy redis_proxy with Maglev hashing, retries, and health checks.
- Redis masters/replicas pre-tuned for AOF, ACLs, and large workloads.
- Shell automation for deployment, scaling, backups, log rotation, and verification.
- Reference monitoring assets (exporter setup, scrape configs, alert rules, Grafana dashboard).
- A disposable integration harness to prove functionality before production changes.

---

## Why RedisForge

| Capability | Benefit |
|------------|---------|
| **Envoy-managed endpoint** | Applications connect to one TLS URL; no client awareness of cluster slots. |
| **Hardened Redis images** | 64-bit limits, command remaps, ACL enforcement, AOF by default. |
| **Idempotent scripts** | `deploy.sh`, `init-cluster.sh`, `scale.sh`, etc. validate prerequisites and fail safely. |
| **TLS-first design** | Helper script to mint certs for lower envs; production expects CA-issued keys. |
| **Monitoring-ready** | Exporter installer + Prometheus/Alertmanager/Grafana snippets integrate with your stack. |
| **Operations tooling** | Scaling, backup, log rotation, and smoke testing commands live in one repo. |

---

## Architecture

```
Clients ── TLS ──▶ Envoy redis_proxy ── TCP ──▶ Redis Masters (slots 0..16383)
                                     └────────▶ Redis Replicas (async)
                   ▲
                   └── Prometheus scrapes Envoy (9901), redis_exporter (9121), node_exporter (9100)
```

- Envoy terminates TLS on `6379`, authenticates via Redis ACL users, and routes keys to the correct master.
- Three masters own the hash slots; each has a dedicated replica ready for promotion.
- Redis cluster bus traffic flows on `16379` inside your VPC.
- Exporters expose metrics on localhost and are scraped by your existing Prometheus servers.

---

## Requirements

| Category | Details |
|----------|---------|
| Compute | 3× Redis nodes (e.g., r6i.2xlarge) + 1× Envoy node (e.g., c6i.large). |
| OS | Amazon Linux 2023 / Ubuntu 22.04+ with Docker Engine 20.10+. |
| Networking | Security groups for Redis 6379/16379 and Envoy 6379/9901 as appropriate. |
| Monitoring | Existing Prometheus, Alertmanager, Grafana (RedisForge only ships configs). |
| Storage | Local volumes sized for AOF retention; optional S3 bucket for backups. |
| Access | SSH + sudo on each host; `redis-cli` available. |

---

## Deployment Workflow

1. **Prepare hosts**
   ```bash
   sudo yum install -y docker git redis
   sudo systemctl enable --now docker
   sudo usermod -aG docker $USER && newgrp docker
   ```

2. **Clone repo & copy `.env`**
   ```bash
   git clone https://github.com/your-org/RedisForge.git
   cd RedisForge
   cp env.example .env
   ```

3. **Populate `.env`**
   - Fill in strong passwords for `REDIS_REQUIREPASS`, ACL/readonly/monitor/replication users.
   - Set `REDIS_MAXMEMORY`, `REDIS_CLUSTER_ANNOUNCE_IP`, `REDIS_MASTER_{1..3}_HOST`.
   - Configure backup parameters if using S3.

4. **Generate TLS cert for Envoy**
   ```bash
   ./scripts/generate-certs.sh config/tls/prod
   ```
   Copy `server.crt` and `server.key` to each Envoy host (mount at `/etc/envoy/certs`). Replace with CA-issued certs for production.

5. **Deploy Redis on each node**
   ```bash
   export REDIS_CLUSTER_ANNOUNCE_IP=$(hostname -I | awk '{print $1}')
   ./scripts/deploy.sh redis
   docker ps | grep redis-master
   ```

6. **Initialize the cluster**
   ```bash
   REDIS_REQUIREPASS=$REDIS_PASS ./scripts/init-cluster.sh \
     "10.0.1.10:6379,10.0.2.11:6379,10.0.3.12:6379,10.0.1.13:6379,10.0.2.14:6379,10.0.3.15:6379"
   ```

7. **Deploy Envoy**
   ```bash
   ./scripts/deploy.sh envoy
   curl -k https://<envoy-ip>:6379 -u app_user:<password> ping
   ```

8. **Smoke test via Envoy**
   ```bash
   TLS_ENABLED=true TLS_CA_FILE=config/tls/prod/ca.crt ./scripts/test-cluster.sh <envoy-ip> 6379
   ```

For a detailed guide see [`docs/quickstart.md`](./docs/quickstart.md).

---

## Monitoring Integration

RedisForge assumes your Prometheus/Alertmanager/Grafana stack already exists. Use the provided assets as references:

1. **Exporters** – run `./scripts/setup-exporters.sh` on each Redis host; it installs redis_exporter (9121) and node_exporter (9100) using host networking.

2. **Prometheus scrape example** (add to your existing `prometheus.yml`):
   ```yaml
   - job_name: 'redisforge-redis'
     static_configs:
       - targets: ['10.0.1.10:9121','10.0.2.11:9121','10.0.3.12:9121']
         labels: {role: redis}
   - job_name: 'redisforge-node'
     static_configs:
       - targets: ['10.0.1.10:9100','10.0.2.11:9100','10.0.3.12:9100']
         labels: {role: system}
   - job_name: 'redisforge-envoy'
     metrics_path: /stats/prometheus
     static_configs:
       - targets: ['<envoy-ip>:9901']
   ```

3. **Alerting** – adapt `monitoring/alertmanager/alertmanager.yaml` to your notification channels (Discord example included).

4. **Grafana** – import `monitoring/grafana/dashboards/redisforge-dashboard.json` and point it at your Prometheus datasource.

---

## Operations & Runbooks

### Scaling
```bash
# Add master
REDIS_REQUIREPASS=$PASS ./scripts/scale.sh add 10.0.4.20:6379 --role master

# Add replica
REDIS_REQUIREPASS=$PASS ./scripts/scale.sh add 10.0.5.30:6379 --role replica --replica-of <master-node-id>

# Remove node
REDIS_REQUIREPASS=$PASS ./scripts/scale.sh remove <node-id>
```

### Backups
```bash
BACKUP_S3_BUCKET=s3://my-bucket/redisforge ./scripts/backup.sh
```
Schedule via cron for regular snapshots.

### Log rotation
```bash
./scripts/log-rotate.sh /var/log/redis 1024 7
```

### TLS rotation
```bash
./scripts/generate-certs.sh config/tls/prod
# copy new files to Envoy hosts and restart the container/service
```

### Health checks
```bash
redis-cli -h <envoy> -p 6379 --tls --cacert config/tls/prod/ca.crt -a $REDIS_REQUIREPASS ping
curl https://<envoy-ip>:9901/stats/prometheus | grep envoy_cluster_upstream_rq_total
```

---

## Integration Testing

Before merging or deploying, run the disposable compose harness:

```bash
./scripts/generate-certs.sh config/tls/dev
tests/run-integration.sh
```

It builds the Redis and Envoy images, launches a 3×3 cluster + Envoy, initializes slots, runs `scripts/test-cluster.sh` through Envoy’s TLS listener, and tears everything down. Use it locally or wire it into CI.

---

## Repository Layout

```
RedisForge/
├── config/ (Envoy + Redis templates, TLS README)
├── docker/ (Redis & Envoy Dockerfiles / entrypoints)
├── docs/quickstart.md
├── monitoring/ (Prometheus/Alertmanager/Grafana references)
├── scripts/ (deploy, scale, backup, exporters, tests, cert tooling)
├── tests/ (integration compose stack + runner)
├── env.example
├── LICENSE
└── README.md
```

---

## Contributing

1. Fork the repo and create a feature branch.
2. Implement your changes (code + docs).
3. Run `tests/run-integration.sh` or an equivalent CI job to prove the cluster still works.
4. Open a PR with a clear description and test evidence.

Keep scripts idempotent, document behavior changes, and never commit secrets or private keys.

---

## License

RedisForge is distributed under the [MIT License](./LICENSE).

---

## Support

- Issues & ideas: [GitHub Issues](https://github.com/your-org/RedisForge/issues)
- Discussions & design questions: open a Discussion or PR.
- Security disclosures: contact the maintainers privately.

Built with ❤️ to make DevOps life easier when running serious Redis clusters.
