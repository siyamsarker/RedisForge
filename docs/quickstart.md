# RedisForge - Quick Start Guide

**📖 Complete step-by-step production deployment guide for AWS EC2**

> 👈 **Back to**: [Main README](../README.md) | **Related**: [Monitoring Troubleshooting](./monitoring-troubleshooting.md) | [Discord Alerts](./discord-alerts-setup.md)

Get RedisForge running in production on AWS EC2 in under 30 minutes.

---

## Prerequisites

- **AWS Account** with EC2 access
- **4 EC2 Instances** (see sizing below)
- **Docker** installed on all instances
- **Existing Prometheus & Grafana** for monitoring
- **S3 Bucket** for backups (optional)

---

## EC2 Instance Requirements

| Role | Count | Type | vCPU | RAM | AZ |
|------|-------|------|------|-----|-----|
| Redis Master | 3 | r6i.2xlarge | 8 | 64 GB | Multi-AZ |
| Envoy Proxy | 1 | c6i.large | 2 | 4 GB | Any AZ |

**Network Requirements:**
- VPC with 3 availability zones
- Security groups configured (see below)
- Private subnets recommended

---

## Security Group Configuration

### Redis Instances

| Type | Protocol | Port | Source | Purpose |
|------|----------|------|--------|---------|
| Inbound | TCP | 6379 | Redis SG | Redis cluster |
| Inbound | TCP | 16379 | Redis SG | Cluster bus |
| Inbound | TCP | 9121 | Prometheus IP | Redis exporter |
| Inbound | TCP | 9100 | Prometheus IP | Node exporter |
| Inbound | TCP | 22 | Admin IP | SSH |

### Envoy Instance

| Type | Protocol | Port | Source | Purpose |
|------|----------|------|--------|---------|
| Inbound | TCP | 6379 | App SG | Redis proxy |
| Inbound | TCP | 9901 | Prometheus IP | Envoy metrics |
| Inbound | TCP | 22 | Admin IP | SSH |

---

## Step 1: Provision EC2 Instances

### Launch Instances

```bash
# Example using AWS CLI (adjust as needed)
aws ec2 run-instances \
  --image-id ami-0c55b159cbfafe1f0 \  # Amazon Linux 2023 or Ubuntu 24.04 LTS
  --instance-type r6i.2xlarge \
  --count 3 \
  --key-name your-key \
  --security-group-ids sg-xxxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=redisforge-redis-1}]'
```

Note the private IPs:
- Redis-1: `10.0.1.10` (AZ-a)
- Redis-2: `10.0.2.11` (AZ-b)
- Redis-3: `10.0.3.12` (AZ-c)
- Envoy: `10.0.1.20` (AZ-a)

---

## Step 2: Install Docker on All Instances

SSH into each instance and run:

```bash
# Amazon Linux 2023
sudo yum update -y
sudo yum install -y docker git redis
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user
newgrp docker

# Ubuntu 24.04 LTS
sudo apt update
sudo apt install -y docker.io docker-compose-v2 git redis-tools curl jq
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ubuntu
newgrp docker
```

Verify Docker is running:
```bash
docker --version
docker ps
```

---

## Step 3: Clone Repository

On **all 4 instances**:

```bash
git clone https://github.com/your-org/RedisForge.git
cd RedisForge
```

---

## Step 4: Configure Environment

On **all instances**, create `.env`:

```bash
cp env.example .env
```

### Generate Strong Passwords

```bash
# Generate random passwords
REDIS_PASS=$(openssl rand -base64 32)
APP_PASS=$(openssl rand -base64 32)
READONLY_PASS=$(openssl rand -base64 32)
MONITOR_PASS=$(openssl rand -base64 32)
REPL_PASS=$(openssl rand -base64 32)

echo "REDIS_REQUIREPASS=$REDIS_PASS"
echo "REDIS_ACL_PASS=$APP_PASS"
echo "REDIS_READONLY_PASS=$READONLY_PASS"
echo "REDIS_MONITOR_PASS=$MONITOR_PASS"
echo "REDIS_REPLICATION_PASS=$REPL_PASS"

# Save these passwords securely!
```

### Edit `.env` File

Update the following in `.env` on **all instances**:

```bash
# Authentication (use passwords generated above)
REDIS_REQUIREPASS=your_redis_password
REDIS_ACL_PASS=your_app_password
REDIS_READONLY_PASS=your_readonly_password
REDIS_MONITOR_PASS=your_monitor_password
REDIS_REPLICATION_PASS=your_replication_password

# Redis Cluster IPs (use actual private IPs)
REDIS_MASTER_1_HOST=10.0.1.10
REDIS_MASTER_2_HOST=10.0.2.11
REDIS_MASTER_3_HOST=10.0.3.12

# Memory configuration (75% of available RAM)
REDIS_MAXMEMORY=48gb

# Backup configuration
BACKUP_S3_BUCKET=s3://your-backup-bucket/redisforge
AWS_REGION=us-east-1

# Exporters
REDIS_EXPORTER_PORT=9121
NODE_EXPORTER_PORT=9100
```

### Instance-Specific Configuration

On **each Redis instance**, set its announce IP:

```bash
# Redis-1 (10.0.1.10)
echo "REDIS_CLUSTER_ANNOUNCE_IP=10.0.1.10" >> .env

# Redis-2 (10.0.2.11)
echo "REDIS_CLUSTER_ANNOUNCE_IP=10.0.2.11" >> .env

# Redis-3 (10.0.3.12)
echo "REDIS_CLUSTER_ANNOUNCE_IP=10.0.3.12" >> .env
```

---

## Step 5: Deploy Redis Nodes

On **each of the 3 Redis instances**:

```bash
./scripts/deploy.sh redis
```

Verify deployment:
```bash
docker ps | grep redis-master
docker logs redis-master

# Check Redis is responding
docker exec redis-master redis-cli -a "$REDIS_REQUIREPASS" PING
# Expected: PONG
```

---

## Step 6: Initialize Cluster

From **any Redis instance** or admin machine with redis-cli:

```bash
# Build cluster from 3 masters + 3 replicas (6 nodes minimum)
# Replace IPs with your actual private IPs

REDIS_REQUIREPASS=your_password \
./scripts/init-cluster.sh \
  "10.0.1.10:6379,10.0.2.11:6379,10.0.3.12:6379,10.0.1.10:6379,10.0.2.11:6379,10.0.3.12:6379"
```

**Note**: For true HA, deploy 6 separate Redis instances (3 masters + 3 replicas). The above command assumes replicas run on same hosts as masters.

Verify cluster:
```bash
redis-cli -h 10.0.1.10 -a your_password cluster info
redis-cli -h 10.0.1.10 -a your_password cluster nodes
```

Expected output:
```
cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:6
...
```

---

## Step 7: Deploy Envoy Proxy

On **Envoy instance**:

```bash
./scripts/deploy.sh envoy
```

Verify deployment:
```bash
docker ps | grep envoy-proxy
docker logs envoy-proxy

# Check Envoy admin interface
curl http://localhost:9901/clusters | grep redis
curl http://localhost:9901/stats/prometheus | head
```

Test Redis through Envoy:
```bash
redis-cli -h localhost -p 6379 -a your_password PING
# Expected: PONG

redis-cli -h localhost -p 6379 -a your_password SET test "Hello RedisForge"
redis-cli -h localhost -p 6379 -a your_password GET test
# Expected: "Hello RedisForge"
```

---

## Step 8: Deploy Monitoring Exporters

On **each Redis instance**:

```bash
./scripts/setup-exporters.sh
```
```

This deploys:
- **redis_exporter** on port 9121
- **node_exporter** on port 9100

Verify exporters:
```bash
docker ps | grep exporter

# Test metrics endpoints
curl http://localhost:9121/metrics | grep redis_up
curl http://localhost:9100/metrics | grep node_cpu
```

---

## Step 9: Configure Push-Based Monitoring

RedisForge uses **PUSH-based monitoring** with Prometheus Push Gateway.

### Architecture
```
Exporters → push-metrics.sh (every 30s) → Push Gateway → Prometheus → Grafana
```

### Configuration

**On each Redis instance**, configure Push Gateway URL:

```bash
# Edit .env
echo "PROMETHEUS_PUSHGATEWAY=http://your-pushgateway:9091" >> .env
echo "METRICS_PUSH_INTERVAL=30" >> .env  # Push every 30 seconds
```

### Setup Continuous Push Service

**Option A: Using systemd (Recommended for Production)**

On **each Redis instance**:

```bash
# Copy systemd service file
sudo cp monitoring/systemd/redisforge-metrics-push.service /etc/systemd/system/

# Update service file paths if needed
sudo nano /etc/systemd/system/redisforge-metrics-push.service

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable redisforge-metrics-push
sudo systemctl start redisforge-metrics-push

# Verify service is running
sudo systemctl status redisforge-metrics-push

# View logs
sudo journalctl -u redisforge-metrics-push -f
```

**Option B: Using Screen (Testing/Development)**

```bash
# Start in screen session
screen -S metrics-push
cd /home/ec2-user/RedisForge
./scripts/push-metrics.sh

# Detach with Ctrl+A, then D

# Re-attach later
screen -r metrics-push
```

**Option C: Using nohup (Background Process)**

```bash
nohup ./scripts/push-metrics.sh > /var/log/metrics-push.log 2>&1 &
```

### Configure Prometheus to Scrape Push Gateway

In your **Prometheus server** configuration (`prometheus.yml`):

```yaml
scrape_configs:
  - job_name: 'pushgateway'
    honor_labels: true  # Preserve labels from pushed metrics
    static_configs:
    - targets: ['<pushgateway-host>:9091']
      labels:
        cluster: 'redisforge'
```

**Note**: Replace `<pushgateway-host>` with your Push Gateway server IP/hostname.

Reload Prometheus:
```bash
curl -X POST http://your-prometheus:9090/-/reload
```

Verify targets in Prometheus UI:
```
http://your-prometheus:9090/targets
```

### Verify Push Metrics

Check Push Gateway has received metrics:
```bash
curl http://<pushgateway-host>:9091/metrics | grep redisforge
```

Query metrics in Prometheus:
```bash
curl 'http://your-prometheus:9090/api/v1/query?query=redis_up'
```

### Important Notes

**Data Flow:**
1. **Exporters** (redis_exporter, node_exporter) expose current metrics at `:9121` and `:9100`
2. **push-metrics.sh** reads exporters every 30 seconds (configurable) and pushes to Push Gateway
3. **Push Gateway** stores metrics in memory until Prometheus scrapes
4. **Prometheus** scrapes Push Gateway and stores in time-series DB
5. **Grafana** queries Prometheus for visualization

**Data Storage:**
- ❌ Exporters **DO NOT** store historical data locally (only current state)
- ✅ Push Gateway stores latest metrics in memory (lost on restart)
- ✅ Prometheus stores all historical data on disk

**Push Interval:**
- Default: **30 seconds** (configurable via `METRICS_PUSH_INTERVAL`)
- Adjust based on your monitoring needs (higher frequency = more data)

**Troubleshooting:**
```bash
# Check exporters are running
docker ps | grep exporter

# Test exporter endpoints
curl http://localhost:9121/metrics | grep redis_up
curl http://localhost:9100/metrics | grep node_cpu

# Check systemd service status
sudo systemctl status redisforge-metrics-push
sudo journalctl -u redisforge-metrics-push --since "10 minutes ago"

# Manual test push
./scripts/push-metrics.sh
```

---

## Step 10: Import Grafana Dashboard

In your **existing Grafana** instance:

1. Navigate to **Dashboards → Import**
2. Click **Upload JSON file**
3. Select `monitoring/grafana/dashboards/redisforge-dashboard.json`
4. Choose your Prometheus datasource
5. Click **Import**

The dashboard includes:
- Redis cluster health & topology
- Memory usage & evictions
- Commands per second
- Cache hit/miss ratio
- Replication lag
- Envoy request rate & latency
- System metrics (CPU, memory, disk)

---

## Step 11: Configure Automated Backups

On **each Redis instance**, set up cron for hourly backups:

```bash
# Edit crontab
crontab -e

# Add hourly backup job
0 * * * * cd /home/ec2-user/RedisForge && BACKUP_S3_BUCKET=s3://your-bucket/backups ./scripts/backup.sh >> /var/log/redis-backup.log 2>&1

# Add daily log rotation
0 2 * * * cd /home/ec2-user/RedisForge && ./scripts/log-rotate.sh /var/log/redis 1024 7 >> /var/log/redis-rotate.log 2>&1
```

Ensure IAM role attached to EC2 instances has S3 write permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::your-backup-bucket/redisforge/*"
    }
  ]
}
```

## Step 10: Import Grafana Dashboard

In your **existing Grafana** instance:

1. Navigate to **Dashboards → Import**
2. Click **Upload JSON file**
3. Select `monitoring/grafana/dashboards/redisforge-dashboard.json`
4. Choose your Prometheus datasource
5. Click **Import**

The dashboard includes:
- Redis cluster health & topology
- Memory usage & evictions
- Commands per second
- Cache hit/miss ratio
- Replication lag
- Envoy request rate & latency
- System metrics (CPU, memory, disk)

---

## Step 11: Configure Automated Backups

On **each Redis instance**, set up cron for hourly backups:

```bash
# Edit crontab
crontab -e

# Add hourly backup job
0 * * * * cd /home/ec2-user/RedisForge && BACKUP_S3_BUCKET=s3://your-bucket/backups ./scripts/backup.sh >> /var/log/redis-backup.log 2>&1

# Add daily log rotation
0 2 * * * cd /home/ec2-user/RedisForge && ./scripts/log-rotate.sh /var/log/redis 1024 7 >> /var/log/redis-rotate.log 2>&1
```

Ensure IAM role attached to EC2 instances has S3 write permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::your-backup-bucket/redisforge/*"
    }
  ]
}
```

---

## Step 12: Test the Deployment

Run comprehensive tests:

```bash
# From any machine with redis-cli
./scripts/test-cluster.sh 10.0.1.20 6379

# Test cluster operations
redis-cli -h 10.0.1.20 -p 6379 -a your_password CLUSTER INFO
redis-cli -h 10.0.1.20 -p 6379 -a your_password INFO replication
redis-cli -h 10.0.1.20 -p 6379 -a your_password INFO memory

# Benchmark (optional)
redis-benchmark -h 10.0.1.20 -p 6379 -a your_password -t set,get -n 100000 -c 50
```

---

## Next Steps

### Configure Your Applications

Point your applications to the Envoy endpoint:

```python
# Python example
import redis

r = redis.StrictRedis(
    host='10.0.1.20',  # Envoy private IP
    port=6379,
    password='your_password',
    decode_responses=True
)

r.set('key', 'value')
print(r.get('key'))
```

### Set Up Alerts

Add alerting rules to Prometheus (see README for examples):
- Redis instance down
- High memory usage
- Cluster unhealthy
- Envoy high error rate

### Enable CloudWatch Logs

For centralized logging:

```bash
# Install CloudWatch agent
sudo yum install -y amazon-cloudwatch-agent

# Configure log collection
# See AWS documentation for setup
```

---

## Troubleshooting

### Redis not starting
```bash
# Check logs
docker logs redis-master

# Check permissions
ls -la data/ logs/

# Check .env file
cat .env | grep REDIS_
```

### Cluster initialization fails
```bash
# Verify all nodes are reachable
for ip in 10.0.1.10 10.0.2.11 10.0.3.12; do
  redis-cli -h $ip -p 6379 -a your_password PING
done

# Check cluster status on each node
redis-cli -h 10.0.1.10 -a your_password cluster info
```

### Envoy can't reach Redis
```bash
# Check Envoy logs
docker logs envoy-proxy

# Verify Redis IPs in config
grep REDIS_MASTER .env

# Test connectivity from Envoy host
telnet 10.0.1.10 6379
```

### Exporters not working
```bash
# Check exporter logs
docker logs redis-exporter
docker logs node-exporter

# Test metrics manually
curl http://localhost:9121/metrics
curl http://localhost:9100/metrics
```

---

## Maintenance Operations

### Add a New Redis Node
```bash
# On new instance
./scripts/deploy.sh redis
./scripts/setup-exporters.sh

# Add to cluster
REDIS_REQUIREPASS=your_password SEED=10.0.1.10:6379 \
./scripts/scale.sh add 10.0.4.13:6379
```

### Remove a Redis Node
```bash
# Get node ID
redis-cli -h 10.0.1.10 -a your_password cluster nodes

# Remove node
REDIS_REQUIREPASS=your_password SEED=10.0.1.10:6379 \
./scripts/scale.sh remove <node-id>
```

### Update Configuration
```bash
# Stop container
docker stop redis-master

# Edit config
vi config/redis/redis.conf

# Restart
docker start redis-master
```

---

## Performance Tuning

### System Level Tuning

On all Redis instances:

```bash
# Increase file descriptors
echo "* soft nofile 100000" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 100000" | sudo tee -a /etc/security/limits.conf

# Kernel tuning
sudo tee -a /etc/sysctl.conf << EOF
net.core.somaxconn = 65535
vm.overcommit_memory = 1
net.ipv4.tcp_max_syn_backlog = 65535
EOF

sudo sysctl -p

# Disable transparent huge pages
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

Add to `/etc/rc.local` for persistence:
```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

---

## Cost Optimization

### EC2 Instance Recommendations

| Workload | Instance Type | Monthly Cost (us-east-1) |
|----------|---------------|--------------------------|
| Small (<1M ops/day) | r6i.large | ~$120/instance |
| Medium (1-10M ops/day) | r6i.xlarge | ~$240/instance |
| Large (10M+ ops/day) | r6i.2xlarge | ~$480/instance |

### Savings Tips

1. Use Reserved Instances (up to 72% savings)
2. Consider Spot Instances for non-critical replicas
3. Enable EBS GP3 volumes instead of GP2
4. Use VPC endpoints to avoid data transfer costs
5. Implement lifecycle policies for S3 backups

---

## Security Checklist

- [ ] Strong passwords generated and stored securely
- [ ] Security groups configured with minimal access
- [ ] IAM roles used instead of access keys
- [ ] Private subnets for Redis and Envoy
- [ ] VPC Flow Logs enabled
- [ ] CloudTrail logging enabled
- [ ] SSH keys rotated regularly
- [ ] Redis ACLs reviewed and tested
- [ ] Monitoring alerts configured
- [ ] Backup encryption enabled

---

## 📚 Next Steps

After completing this deployment:

1. **Configure Monitoring** → Continue to [Monitoring Setup](../README.md#monitoring-setup) in main README
2. **Set Up Alerts** → Follow [Discord Alerts Setup Guide](./discord-alerts-setup.md)
3. **Troubleshoot Issues** → See [Monitoring Troubleshooting Guide](./monitoring-troubleshooting.md)
4. **Scale Your Cluster** → See [Operations Guide](../README.md#operations) in main README

---

## 📞 Support

- **Main Documentation**: [README.md](../README.md)
- **Monitoring Issues**: [monitoring-troubleshooting.md](./monitoring-troubleshooting.md)
- **Discord Setup**: [discord-alerts-setup.md](./discord-alerts-setup.md)
- **Report Issues**: [GitHub Issues](https://github.com/siyamsarker/RedisForge/issues)

---

<div align="center">

**🎉 Deployment Complete!**

[👈 Back to Main README](../README.md) | [🐛 Report Issue](https://github.com/siyamsarker/RedisForge/issues)

</div>

---

**🎉 Congratulations! Your production RedisForge cluster is now running!**
