# RedisForge - Monitoring & Troubleshooting Guide

**🔧 Comprehensive guide for debugging and fixing monitoring issues**

> 👈 **Back to**: [Main README](../README.md) | **Related**: [Quick Start](./quickstart.md) | [Discord Alerts](./discord-alerts-setup.md)

This guide helps you diagnose and fix issues with the push-based monitoring system.

---

## 🎯 Quick Diagnosis

### Check if Monitoring is Working

```bash
# 1. Check if exporters are running
docker ps | grep exporter

# 2. Check if push service is active
sudo systemctl status redisforge-metrics-push

# 3. Check recent push logs
sudo journalctl -u redisforge-metrics-push -n 20

# 4. Verify Push Gateway has metrics
curl http://<pushgateway>:9091/metrics | grep redis_up

# 5. Query Prometheus for latest metrics
curl 'http://<prometheus>:9090/api/v1/query?query=redis_up' | jq
```

---

## 🔍 Common Issues and Solutions

### Issue 1: Push Gateway Connection Refused

**Symptoms:**
```
curl: (7) Failed to connect to pushgateway:9091: Connection refused
```

**Causes:**
- Push Gateway is down
- Incorrect URL in `.env`
- Network/firewall blocking connection
- Push Gateway not listening on expected port

**Solutions:**

```bash
# A. Verify Push Gateway URL in .env
cat .env | grep PROMETHEUS_PUSHGATEWAY
# Should be: PROMETHEUS_PUSHGATEWAY=http://<host>:9091

# B. Check if Push Gateway is reachable
curl http://<pushgateway>:9091/-/healthy
# Expected: Healthy

# C. Test network connectivity
telnet <pushgateway-host> 9091
nc -zv <pushgateway-host> 9091

# D. Check Push Gateway logs (if you manage it)
docker logs pushgateway  # If running in Docker
journalctl -u pushgateway -n 50  # If systemd service

# E. Verify Push Gateway is listening
netstat -tuln | grep 9091
ss -tuln | grep 9091
```

**Impact on Redis/Envoy:**
- ✅ **NO IMPACT** - Redis and Envoy continue operating normally
- ❌ Metrics visibility lost until resolved

---

### Issue 2: Exporters Not Running

**Symptoms:**
```bash
docker ps | grep exporter
# No results
```

**Causes:**
- Exporters crashed or were stopped
- Docker daemon issues
- Resource exhaustion (OOM)

**Solutions:**

```bash
# A. Check exporter container status
docker ps -a | grep exporter

# B. View exporter logs
docker logs redis-exporter
docker logs node-exporter

# C. Restart exporters
./scripts/setup-exporters.sh

# D. Verify exporters are responding
curl http://localhost:9121/metrics | head -20  # Redis exporter
curl http://localhost:9100/metrics | head -20  # Node exporter

# E. Check for resource issues
docker stats
free -h
df -h
```

**Impact on Redis/Envoy:**
- ✅ **NO IMPACT** - Core services unaffected
- ❌ Metrics collection stops

---

### Issue 3: Push Service Not Running

**Symptoms:**
```bash
sudo systemctl status redisforge-metrics-push
# Status: inactive (dead) or failed
```

**Causes:**
- Service crashed
- Invalid configuration in .env
- Permission issues
- Script errors

**Solutions:**

```bash
# A. Check service status details
sudo systemctl status redisforge-metrics-push -l

# B. View recent logs
sudo journalctl -u redisforge-metrics-push -n 50 --no-pager

# C. Verify .env configuration
cat .env | grep -E 'PROMETHEUS_PUSHGATEWAY|METRICS_PUSH_INTERVAL'

# D. Test script manually
cd /home/ec2-user/RedisForge
./scripts/push-metrics.sh
# Watch for errors

# E. Restart service
sudo systemctl restart redisforge-metrics-push
sudo systemctl status redisforge-metrics-push

# F. Enable if not enabled
sudo systemctl enable redisforge-metrics-push

# G. Check for permission issues
ls -la scripts/push-metrics.sh
# Should be executable: -rwxr-xr-x
chmod +x scripts/push-metrics.sh
```

**Impact on Redis/Envoy:**
- ✅ **NO IMPACT** - Core services unaffected
- ❌ Metrics not pushed until service restarts

---

### Issue 4: Metrics Not Appearing in Prometheus

**Symptoms:**
- Push Gateway shows metrics ✅
- Prometheus doesn't have data ❌

**Causes:**
- Prometheus not scraping Push Gateway
- Incorrect job configuration
- Network issues between Prometheus and Push Gateway

**Solutions:**

```bash
# A. Check Prometheus targets
curl http://<prometheus>:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="pushgateway")'

# B. Verify Prometheus scrape config
cat /etc/prometheus/prometheus.yml | grep -A10 pushgateway

# C. Check if Push Gateway is reachable from Prometheus
# (Run on Prometheus server)
curl http://<pushgateway>:9091/metrics | head

# D. Reload Prometheus configuration
curl -X POST http://<prometheus>:9090/-/reload

# E. Check Prometheus logs
journalctl -u prometheus -n 50
docker logs prometheus  # If Dockerized

# F. Query for specific metric
curl 'http://<prometheus>:9090/api/v1/query?query=redis_up' | jq
```

**Impact on Redis/Envoy:**
- ✅ **NO IMPACT** - Core services unaffected
- ❌ Historical data gap in Prometheus

---

### Issue 5: Stale Metrics in Grafana

**Symptoms:**
- Grafana dashboards show old data
- "No data" messages
- Last update timestamp is old

**Causes:**
- Entire monitoring pipeline broken
- Grafana datasource misconfigured
- Time range issues in dashboard

**Solutions:**

```bash
# A. Check each component in sequence
# 1. Exporters
curl http://localhost:9121/metrics | grep redis_up
curl http://localhost:9100/metrics | grep node_cpu

# 2. Push Gateway
curl http://<pushgateway>:9091/metrics | grep redis_up

# 3. Prometheus
curl 'http://<prometheus>:9090/api/v1/query?query=redis_up'

# 4. Grafana datasource
# Go to Grafana → Configuration → Data Sources → Test

# B. Check push timestamps
curl http://<pushgateway>:9091/metrics | grep push_time_seconds

# C. Verify Grafana time range
# Check if "Last 5 minutes" or custom range is appropriate

# D. Refresh Grafana dashboard
# Click refresh icon or set auto-refresh interval

# E. Check Grafana logs
tail -f /var/log/grafana/grafana.log
journalctl -u grafana-server -n 50
```

**Impact on Redis/Envoy:**
- ✅ **NO IMPACT** - Core services unaffected
- ❌ Monitoring visibility reduced

---

### Issue 6: Push Gateway Out of Memory

**Symptoms:**
```
Push Gateway consuming excessive memory
OOMKilled errors in logs
```

**Causes:**
- Too many metrics being pushed
- Prometheus scrape interval too long
- Metrics not being cleaned up

**Solutions:**

```bash
# A. Check Push Gateway memory usage
docker stats pushgateway
ps aux | grep pushgateway

# B. Increase Prometheus scrape frequency
# In prometheus.yml:
scrape_configs:
  - job_name: 'pushgateway'
    scrape_interval: 15s  # Reduce from 30s to 15s

# C. Clean up old metrics manually
curl -X PUT http://<pushgateway>:9091/api/v1/admin/wipe

# D. Restart Push Gateway
docker restart pushgateway
systemctl restart pushgateway

# E. Increase memory limit (if Docker)
docker run --memory=2g prom/pushgateway

# F. Monitor metric cardinality
curl http://<pushgateway>:9091/metrics | grep -c "^[a-z]"
```

**Impact on Redis/Envoy:**
- ✅ **NO IMPACT** - Core services unaffected
- ⚠️ May lose some pushed metrics during restart

---

## 🔧 Emergency Recovery

### Complete Monitoring Stack Restart

If everything is broken, restart the entire monitoring pipeline:

```bash
# On each Redis instance:

# 1. Stop push service
sudo systemctl stop redisforge-metrics-push

# 2. Restart exporters
docker restart redis-exporter node-exporter

# 3. Verify exporters are healthy
sleep 5
curl http://localhost:9121/metrics | head
curl http://localhost:9100/metrics | head

# 4. Test manual push
./scripts/push-metrics.sh

# 5. Restart push service
sudo systemctl restart redisforge-metrics-push

# 6. Verify service is running
sudo systemctl status redisforge-metrics-push
sudo journalctl -u redisforge-metrics-push -f
```

### Verify Redis/Envoy Are Unaffected

```bash
# A. Check Redis cluster health
redis-cli -h localhost -p 6379 -a "$REDIS_REQUIREPASS" cluster info
redis-cli -h localhost -p 6379 -a "$REDIS_REQUIREPASS" cluster nodes

# B. Test Redis operations
redis-cli -h localhost -p 6379 -a "$REDIS_REQUIREPASS" PING
redis-cli -h localhost -p 6379 -a "$REDIS_REQUIREPASS" SET test "monitoring_issue"
redis-cli -h localhost -p 6379 -a "$REDIS_REQUIREPASS" GET test

# C. Check Envoy proxy health
curl http://localhost:9901/clusters | grep redis
curl http://localhost:9901/stats | grep upstream_rq

# D. Test through Envoy
redis-cli -h <envoy-host> -p 6379 -a "$REDIS_REQUIREPASS" PING
```

---

## 📊 Monitoring Health Dashboard

Create a simple health check script:

```bash
#!/bin/bash
# Save as: scripts/check-monitoring-health.sh

source .env

echo "=== RedisForge Monitoring Health Check ==="
echo ""

# Check exporters
echo "1. Checking Exporters..."
if curl -sf http://localhost:9121/metrics > /dev/null; then
  echo "  ✅ redis_exporter is running"
else
  echo "  ❌ redis_exporter is DOWN"
fi

if curl -sf http://localhost:9100/metrics > /dev/null; then
  echo "  ✅ node_exporter is running"
else
  echo "  ❌ node_exporter is DOWN"
fi

# Check push service
echo ""
echo "2. Checking Push Service..."
if systemctl is-active --quiet redisforge-metrics-push; then
  echo "  ✅ push service is active"
else
  echo "  ❌ push service is inactive"
fi

# Check Push Gateway
echo ""
echo "3. Checking Push Gateway..."
if curl -sf "${PROMETHEUS_PUSHGATEWAY}/-/healthy" > /dev/null; then
  echo "  ✅ Push Gateway is reachable"
else
  echo "  ❌ Push Gateway is unreachable"
fi

# Check recent pushes
echo ""
echo "4. Checking Recent Metrics..."
LAST_PUSH=$(curl -s "${PROMETHEUS_PUSHGATEWAY}/metrics" | grep 'push_time_seconds{.*redis-exporter' | tail -1)
if [ -n "$LAST_PUSH" ]; then
  echo "  ✅ Metrics are being pushed"
  echo "  Last push: $LAST_PUSH"
else
  echo "  ❌ No recent metrics found"
fi

echo ""
echo "=== End Health Check ==="
```

**Usage:**
```bash
chmod +x scripts/check-monitoring-health.sh
./scripts/check-monitoring-health.sh
```

---

## 🚨 Key Takeaways

### What Monitoring Failures DO NOT Affect:
- ✅ Redis read/write operations
- ✅ Redis cluster failover
- ✅ Data persistence (AOF/RDB)
- ✅ Envoy proxy routing
- ✅ Client connections
- ✅ Replication sync
- ✅ Application performance

### What You Lose During Monitoring Failures:
- ❌ Real-time metrics visibility
- ❌ Alerting capabilities
- ❌ Historical data collection
- ❌ Dashboard updates
- ❌ Performance trending

### Best Practices:
1. **Set up monitoring alerts** for the monitoring system itself
2. **Test monitoring recovery** regularly
3. **Document your Push Gateway URL** and keep backups
4. **Monitor Push Gateway memory** usage
5. **Keep Prometheus scrape interval** reasonable (15-30s)
6. **Use systemd auto-restart** for push service (already configured)

---

## 📞 Support Checklist

When reporting monitoring issues, gather this information:

```bash
# System info
uname -a
docker --version
systemctl --version

# Service status
sudo systemctl status redisforge-metrics-push
docker ps -a | grep exporter

# Recent logs
sudo journalctl -u redisforge-metrics-push -n 100 --no-pager > push-service.log
docker logs redis-exporter &> redis-exporter.log
docker logs node-exporter &> node-exporter.log

# Configuration
cat .env | grep -E 'PROMETHEUS_PUSHGATEWAY|METRICS_PUSH_INTERVAL'

# Network test
curl -v http://<pushgateway>:9091/-/healthy

# Metrics sample
curl http://localhost:9121/metrics | head -50
curl http://<pushgateway>:9091/metrics | grep redis_up
```

---

## 📚 Related Documentation

- **[Main README](../README.md)** - Project overview and architecture
- **[Quick Start Guide](./quickstart.md)** - Production deployment steps
- **[Discord Alerts Setup](./discord-alerts-setup.md)** - Configure Discord notifications

---

## 📞 Need More Help?

- **GitHub Issues**: [Report a Bug](https://github.com/siyamsarker/RedisForge/issues)
- **Monitoring Setup**: See [Monitoring Setup](../README.md#monitoring-setup) in main README
- **Discord Alerts**: See [Discord Alerts Setup](./discord-alerts-setup.md)

---

<div align="center">

**Remember:** Monitoring failures do NOT affect Redis/Envoy operations! 🎉

[👈 Back to Main README](../README.md)

</div>---

**Remember:** Monitoring failures are **operational issues**, not **critical failures**. Your Redis cluster and Envoy proxy are designed to operate independently of the monitoring stack.
