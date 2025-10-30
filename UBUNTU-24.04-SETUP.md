# Ubuntu 24.04 LTS (Noble Numbat) Setup Guide

**Complete guide for deploying RedisForge on Ubuntu 24.04 LTS**

> 👈 **Back to**: [Main README](./README.md) | [Quick Start Guide](./QUICKSTART.md)

---

## 🎯 Overview

RedisForge is fully compatible with **Ubuntu 24.04 LTS (Noble Numbat)**. This guide provides Ubuntu-specific instructions for production deployment.

---

## 📋 Prerequisites

### System Requirements

| Component | Specification |
|-----------|---------------|
| **OS Version** | Ubuntu 24.04 LTS (Noble Numbat) |
| **Kernel** | 6.8+ |
| **Architecture** | x86_64 (amd64) |
| **CPU** | 2+ cores (8+ for Redis instances) |
| **RAM** | 4GB+ (64GB+ for Redis instances) |
| **Disk** | 50GB+ SSD |

### AWS EC2 Instance Types (Recommended)

- **Redis Masters**: r6i.2xlarge (8 vCPU, 64GB RAM)
- **Envoy Proxy**: c6i.large (2 vCPU, 4-8GB RAM)

---

## 🚀 Step 1: Launch Ubuntu 24.04 LTS Instances

### Using AWS Console

1. **EC2 Dashboard** → **Launch Instance**
2. **Choose AMI**: Ubuntu Server 24.04 LTS
3. **Instance Type**: Select appropriate type (r6i.2xlarge for Redis)
4. **Key Pair**: Select or create SSH key
5. **Network**: VPC with 3 availability zones
6. **Security Group**: Configure ports (see below)
7. **Storage**: 100GB+ GP3 SSD
8. **Launch Instance**

### Using AWS CLI

```bash
# Ubuntu 24.04 LTS AMI (check latest for your region)
UBUNTU_24_04_AMI="ami-0e86e20dae9224db8"  # us-east-1 example

# Launch Redis instance
aws ec2 run-instances \
  --image-id $UBUNTU_24_04_AMI \
  --instance-type r6i.2xlarge \
  --count 3 \
  --key-name your-key-name \
  --security-group-ids sg-xxxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=redisforge-redis-1}]'

# Launch Envoy instance
aws ec2 run-instances \
  --image-id $UBUNTU_24_04_AMI \
  --instance-type c6i.large \
  --key-name your-key-name \
  --security-group-ids sg-xxxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=redisforge-envoy}]'
```

---

## 🔧 Step 2: Initial System Setup

### Connect via SSH

```bash
# Use ubuntu as the default user (not ec2-user)
ssh -i your-key.pem ubuntu@<instance-ip>
```

### Update System Packages

```bash
# Update package index
sudo apt update

# Upgrade installed packages
sudo apt upgrade -y

# Install essential tools
sudo apt install -y \
  curl \
  wget \
  git \
  vim \
  net-tools \
  htop \
  jq \
  ca-certificates \
  gnupg \
  lsb-release
```

### Configure System Limits

```bash
# Increase file descriptors
sudo tee -a /etc/security/limits.conf << EOF
* soft nofile 100000
* hard nofile 100000
ubuntu soft nofile 100000
ubuntu hard nofile 100000
EOF

# Apply immediately
ulimit -n 100000
```

### Kernel Tuning (Redis Optimization)

```bash
# Create sysctl configuration for Redis
sudo tee /etc/sysctl.d/99-redis.conf << EOF
# Memory overcommit (required for Redis)
vm.overcommit_memory = 1

# Disable transparent huge pages
vm.nr_hugepages = 0

# Network tuning
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535

# File descriptors
fs.file-max = 2097152
EOF

# Apply settings
sudo sysctl -p /etc/sysctl.d/99-redis.conf
```

### Disable Transparent Huge Pages (THP)

```bash
# Disable THP (Redis requirement)
sudo tee /etc/systemd/system/disable-thp.service << EOF
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=redis.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable disable-thp
sudo systemctl start disable-thp

# Verify
cat /sys/kernel/mm/transparent_hugepage/enabled
# Should show: always madvise [never]
```

---

## 🐳 Step 3: Install Docker

### Method 1: Docker from Ubuntu Repository (Recommended)

```bash
# Install Docker from Ubuntu official repository
sudo apt update
sudo apt install -y docker.io docker-compose-v2

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Verify Docker version
docker --version
# Should be: Docker version 24.0.5 or newer
```

### Method 2: Docker from Docker Official Repository

```bash
# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Verify installation
docker --version
docker compose version
```

### Add User to Docker Group

```bash
# Add ubuntu user to docker group
sudo usermod -aG docker ubuntu

# Apply group membership (logout/login or use newgrp)
newgrp docker

# Verify (should run without sudo)
docker ps
```

---

## 📦 Step 4: Install Redis Tools

```bash
# Install Redis command-line tools
sudo apt install -y redis-tools

# Verify installation
redis-cli --version
# Should show: redis-cli 7.0.x or newer
```

---

## 🔥 Step 5: Configure Firewall (UFW)

### Enable UFW

```bash
# Enable UFW
sudo ufw --force enable

# Allow SSH (important!)
sudo ufw allow 22/tcp comment 'SSH'
```

### Configure Redis Instance Firewall

```bash
# Redis cluster port
sudo ufw allow from <redis-subnet> to any port 6379 proto tcp comment 'Redis cluster'

# Redis cluster bus port
sudo ufw allow from <redis-subnet> to any port 16379 proto tcp comment 'Redis cluster bus'

# Redis exporter (from Prometheus)
sudo ufw allow from <prometheus-ip> to any port 9121 proto tcp comment 'Redis exporter'

# Node exporter (from Prometheus)
sudo ufw allow from <prometheus-ip> to any port 9100 proto tcp comment 'Node exporter'

# Check status
sudo ufw status numbered
```

### Configure Envoy Instance Firewall

```bash
# Redis proxy port (from applications)
sudo ufw allow from <app-subnet> to any port 6379 proto tcp comment 'Redis proxy'

# Envoy admin/metrics (from Prometheus)
sudo ufw allow from <prometheus-ip> to any port 9901 proto tcp comment 'Envoy admin'

# Check status
sudo ufw status numbered
```

---

## 📥 Step 6: Clone RedisForge Repository

```bash
# Clone repository
cd ~
git clone https://github.com/siyamsarker/RedisForge.git
cd RedisForge

# Verify files
ls -la
```

---

## ⚙️ Step 7: Configure Environment

```bash
# Copy environment template
cp env.example .env

# Generate strong passwords
REDIS_PASS=$(openssl rand -base64 32)
APP_PASS=$(openssl rand -base64 32)

# Edit .env file
nano .env

# Update these settings:
# REDIS_REQUIREPASS=<generated-password>
# REDIS_ACL_PASS=<generated-password>
# REDIS_MAXMEMORY=48gb  # For 64GB instance
# REDIS_CLUSTER_ANNOUNCE_IP=<this-instance-private-ip>
# PROMETHEUS_PUSHGATEWAY=http://<pushgateway-ip>:9091
```

---

## 🚀 Step 8: Deploy RedisForge

### On Each Redis Instance

```bash
# Set announce IP to this instance's private IP
export REDIS_CLUSTER_ANNOUNCE_IP=$(hostname -I | awk '{print $1}')

# Deploy Redis
./scripts/deploy.sh redis

# Verify Redis is running
docker ps | grep redis-master
docker logs redis-master

# Test Redis
docker exec redis-master redis-cli -a "$REDIS_REQUIREPASS" PING
# Expected: PONG
```

### Initialize Redis Cluster

From any machine with redis-cli:

```bash
# Install redis-tools if not already installed
sudo apt install -y redis-tools

# Initialize cluster (replace IPs with your instances)
REDIS_REQUIREPASS=your_password \
./scripts/init-cluster.sh \
  "10.0.1.10:6379,10.0.2.11:6379,10.0.3.12:6379,10.0.1.13:6379,10.0.2.14:6379,10.0.3.15:6379"

# Verify cluster
redis-cli -h 10.0.1.10 -a your_password cluster info
redis-cli -h 10.0.1.10 -a your_password cluster nodes
```

### On Envoy Instance

```bash
# Deploy Envoy proxy
./scripts/deploy.sh envoy

# Verify Envoy is running
docker ps | grep envoy-proxy
docker logs envoy-proxy

# Check Envoy admin interface
curl http://localhost:9901/clusters
```

---

## 📊 Step 9: Setup Monitoring

### Deploy Exporters on Each Redis Instance

```bash
# Deploy redis_exporter and node_exporter
./scripts/setup-exporters.sh

# Verify exporters are running
docker ps | grep exporter
curl http://localhost:9121/metrics | head
curl http://localhost:9100/metrics | head
```

### Configure Continuous Push Service

```bash
# Copy systemd service file
sudo cp monitoring/systemd/redisforge-metrics-push.service /etc/systemd/system/

# Update service file paths if needed
sudo nano /etc/systemd/system/redisforge-metrics-push.service

# Change User from ec2-user to ubuntu:
# User=ubuntu
# WorkingDirectory=/home/ubuntu/RedisForge

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable redisforge-metrics-push
sudo systemctl start redisforge-metrics-push

# Verify service is running
sudo systemctl status redisforge-metrics-push
sudo journalctl -u redisforge-metrics-push -f
```

---

## 🔍 Step 10: Verification

### Check System Services

```bash
# Check Docker
sudo systemctl status docker

# Check metrics push service
sudo systemctl status redisforge-metrics-push

# Check UFW firewall
sudo ufw status
```

### Verify Redis Cluster

```bash
# Cluster health
redis-cli -h <any-node> -a your_password cluster info

# Node status
redis-cli -h <any-node> -a your_password cluster nodes

# Test read/write
redis-cli -h <envoy-ip> -a your_password SET test "Ubuntu 24.04 works!"
redis-cli -h <envoy-ip> -a your_password GET test
```

### Check Monitoring

```bash
# Verify exporters
curl http://localhost:9121/metrics | grep redis_up
curl http://localhost:9100/metrics | grep node_cpu

# Check Push Gateway
curl http://<pushgateway>:9091/metrics | grep redis_up

# Check systemd service logs
sudo journalctl -u redisforge-metrics-push -n 50
```

---

## 🐛 Troubleshooting Ubuntu 24.04

### Issue 1: Docker Permission Denied

```bash
# Ensure user is in docker group
sudo usermod -aG docker ubuntu
newgrp docker

# Verify
groups
# Should include 'docker'

# Test
docker ps
```

### Issue 2: Redis Not Starting

```bash
# Check THP is disabled
cat /sys/kernel/mm/transparent_hugepage/enabled
# Should show: [never]

# Check overcommit_memory
sysctl vm.overcommit_memory
# Should be: 1

# Check Docker logs
docker logs redis-master
```

### Issue 3: UFW Blocking Connections

```bash
# Check UFW rules
sudo ufw status numbered

# Check if port is listening
sudo netstat -tulpn | grep 6379

# Allow specific IP
sudo ufw allow from <ip-address> to any port 6379
```

### Issue 4: systemd Service Not Starting

```bash
# Check service status
sudo systemctl status redisforge-metrics-push

# View logs
sudo journalctl -u redisforge-metrics-push -n 100 --no-pager

# Check file permissions
ls -la /home/ubuntu/RedisForge/scripts/push-metrics.sh
chmod +x /home/ubuntu/RedisForge/scripts/push-metrics.sh

# Verify .env file exists
ls -la /home/ubuntu/RedisForge/.env
```

### Issue 5: AppArmor or SELinux Restrictions

```bash
# Check AppArmor status
sudo aa-status

# If causing issues, you can disable for Docker
sudo ln -s /etc/apparmor.d/docker /etc/apparmor.d/disable/
sudo apparmor_parser -R /etc/apparmor.d/docker
```

---

## 📝 Ubuntu 24.04 Specific Notes

### 1. Default User

- Ubuntu 24.04 uses `ubuntu` as the default user (not `ec2-user`)
- Update systemd service files accordingly
- Home directory: `/home/ubuntu`

### 2. Package Managers

- **APT** is the package manager (not YUM)
- Use `apt` instead of `yum`
- Use `apt update` instead of `yum update`

### 3. Docker Installation

- Package name: `docker.io` (Ubuntu repo) or `docker-ce` (Docker repo)
- Docker Compose: `docker-compose-v2` (Ubuntu) or `docker-compose-plugin` (Docker)

### 4. Redis Tools

- Package name: `redis-tools` (not `redis`)
- Includes `redis-cli`, `redis-benchmark`, etc.

### 5. Firewall

- UFW (Uncomplicated Firewall) is Ubuntu's default firewall
- Amazon Linux uses firewalld instead
- UFW syntax: `sudo ufw allow <port>`

### 6. systemd Paths

- Service files: `/etc/systemd/system/`
- User services: `/home/ubuntu/.config/systemd/user/`
- Journal logs: `/var/log/journal/`

### 7. Kernel Version

- Ubuntu 24.04 ships with Linux kernel 6.8
- No additional kernel updates needed for Redis

---

## ✅ Production Checklist for Ubuntu 24.04

- [ ] Ubuntu 24.04 LTS instances launched
- [ ] System packages updated (`apt update && apt upgrade`)
- [ ] Docker installed and running
- [ ] User added to docker group
- [ ] Redis tools installed (`redis-tools`)
- [ ] System limits configured (`ulimits`, `sysctl`)
- [ ] Transparent Huge Pages disabled
- [ ] UFW firewall configured
- [ ] RedisForge repository cloned
- [ ] `.env` file configured with strong passwords
- [ ] Redis cluster deployed and initialized
- [ ] Envoy proxy deployed
- [ ] Monitoring exporters deployed
- [ ] systemd metrics push service enabled
- [ ] All services verified and tested

---

## 📚 Related Documentation

- **[Main README](./README.md)** - Project overview
- **[Quick Start Guide](./QUICKSTART.md)** - Detailed deployment
- **[Monitoring Troubleshooting](./MONITORING-TROUBLESHOOTING.md)** - Fix issues
- **[Discord Alerts Setup](./DISCORD-ALERTS-SETUP.md)** - Configure alerts

---

## 🆘 Need Help?

- **Ubuntu Documentation**: https://help.ubuntu.com/
- **Docker on Ubuntu**: https://docs.docker.com/engine/install/ubuntu/
- **GitHub Issues**: [Report a Bug](https://github.com/siyamsarker/RedisForge/issues)

---

<div align="center">

**✅ Ubuntu 24.04 LTS Fully Supported!**

[👈 Back to Main README](./README.md) | [📖 Quick Start Guide](./QUICKSTART.md)

</div>
