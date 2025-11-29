# RedisForge Performance Tuning Guide

This guide provides comprehensive performance optimization strategies for RedisForge deployments handling high-throughput workloads.

## Table of Contents
- [Operating System Tuning](#operating-system-tuning)
- [Redis Configuration](#redis-configuration)
- [Envoy Proxy Optimization](#envoy-proxy-optimization)
- [Network Optimization](#network-optimization)
- [Monitoring Performance](#monitoring-performance)
- [Benchmarking](#benchmarking)

---

## Operating System Tuning

### Kernel Parameters

RedisForge includes an automated kernel tuning script for production deployments:

```bash
sudo ./scripts/optimize-kernel.sh
```

**Manual Configuration** (`/etc/sysctl.conf`):

```conf
# Network Performance
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000

# TCP Optimization
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Ephemeral Port Range
net.ipv4.ip_local_port_range = 10000 65535

# File Descriptors
fs.file-max = 1000000

# Virtual Memory
vm.overcommit_memory = 1
vm.swappiness = 1
```

Apply changes:
```bash
sudo sysctl -p
```

### File Descriptor Limits

Edit `/etc/security/limits.conf`:

```conf
redis soft nofile 65536
redis hard nofile 65536
envoy soft nofile 65536
envoy hard nofile 65536
```

### Transparent Huge Pages (THP)

**Disable THP** for Redis (recommended):

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

Make permanent by adding to `/etc/rc.local` or systemd service.

---

## Redis Configuration

### Memory Optimization

**File**: [`config/redis/redis.conf`](file:///Users/technonext/Desktop/Work%20Dir/RedisForge/config/redis/redis.conf)

```conf
# Maximum memory (adjust based on available RAM)
maxmemory 4gb

# Eviction policy for cluster mode
maxmemory-policy allkeys-lru

# Memory optimization
activedefrag yes
active-defrag-ignore-bytes 100mb
active-defrag-threshold-lower 10
active-defrag-threshold-upper 25
```

### Persistence Tuning

**AOF Configuration** (for durability):

```conf
# AOF rewrite optimization
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 128mb
aof-rewrite-incremental-fsync yes

# Disable RDB for cluster nodes (AOF is primary)
save ""
```

**For High-Throughput** (sacrifice some durability):

```conf
# Relax fsync frequency
appendfsync everysec  # Default, good balance
# appendfsync no      # Maximum performance, less durable
```

### Client Connections

```conf
# Maximum simultaneous clients
maxclients 10000

# TCP backlog
tcp-backlog 511

# Timeout for idle clients
timeout 300
```

---

## Envoy Proxy Optimization

### Connection Pool Settings

**File**: [`config/envoy/envoy.yaml`](file:///Users/technonext/Desktop/Work%20Dir/RedisForge/config/envoy/envoy.yaml)

Optimize circuit breakers and connection limits:

```yaml
circuit_breakers:
  thresholds:
  - priority: DEFAULT
    max_connections: 10000      # Increase for high throughput
    max_pending_requests: 10000
    max_requests: 100000
    max_retries: 10
  - priority: HIGH
    max_connections: 20000
    max_pending_requests: 20000
    max_requests: 200000
    max_retries: 5
```

### Upstream Connection Options

```yaml
upstream_connection_options:
  tcp_keepalive:
    keepalive_time: 300
    keepalive_interval: 75
    keepalive_probes: 9
```

### Request Timeout Optimization

```yaml
settings:
  op_timeout: 0.100s  # Adjust based on latency requirements
  enable_redirection: true
  enable_command_stats: true
  max_buffer_size_before_flush: 1024
  buffer_flush_timeout: 0.003s
```

### Cluster Refresh Rate

```yaml
cluster_refresh_rate:
  seconds: 5  # Reduce for faster topology updates (default: 10)
```

---

## Network Optimization

### NIC Settings

**Enable receive-side scaling (RSS)**:

```bash
ethtool -L eth0 combined 4  # Use number of CPU cores
```

**Optimize ring buffer sizes**:

```bash
ethtool -G eth0 rx 4096 tx 4096
```

### MTU Adjustment

For AWS/Cloud deployments, consider jumbo frames:

```bash
ip link set dev eth0 mtu 9000
```

---

## Monitoring Performance

### Key Metrics to Watch

**Redis Metrics**:
- `redis_commands_processed_total` - Operations/sec
- `redis_memory_fragmentation_ratio` - Should be < 1.5
- `redis_keyspace_hits_total / redis_keyspace_misses_total` - Cache hit ratio
- `redis_connected_clients` - Active connections

**Envoy Metrics**:
- `envoy_cluster_upstream_rq_time` - Request latency histograms
- `envoy_cluster_healthy` - Healthy upstream hosts
- `envoy_cluster_upstream_rq_xx` - Error rates

**System Metrics**:
- CPU utilization per core
- Network throughput (Mbps)
- Disk I/O (for AOF writes)

### Grafana Dashboard

Import the enhanced dashboard:

```bash
# Dashboard location
monitoring/grafana/dashboards/redisforge-dashboard.json
```

Key panels:
- Cluster Health & State
- Operations/sec
- Latency percentiles (p50, p95, p99)
- Memory fragmentation
- Circuit breaker stats

---

## Benchmarking

### Using redis-benchmark

**Basic throughput test**:

```bash
redis-benchmark -h envoy -p 6379 -a $PASSWORD \
  --tls --cacert config/tls/dev/ca.crt \
  -c 50 -n 100000 -t get,set
```

**Realistic workload** (70% GET, 30% SET):

```bash
redis-benchmark -h envoy -p 6379 -a $PASSWORD \
  --tls --cacert config/tls/dev/ca.crt \
  -c 200 -n 1000000 -t get,set --ratio 7:3
```

### Using memtier_benchmark

**Installation**:

```bash
apt-get install memtier-benchmark
```

**Cluster benchmark**:

```bash
memtier_benchmark \
  --server=envoy \
  --port=6379 \
  --authenticate=$PASSWORD \
  --tls \
  --tls-skip-verify \
  --cluster-mode \
  --clients=50 \
  --threads=4 \
  --requests=10000 \
  --data-size=128 \
  --key-pattern=R:R \
  --ratio=3:1
```

**Expected Performance** (AWS c5.2xlarge):
- **Throughput**: 100,000+ ops/sec
- **Latency p99**: < 2ms
- **Network**: < 500 Mbps

---

## Performance Troubleshooting

### High Latency

**Check**:
1. Network latency between components
2. CPU saturation on Redis nodes
3. Memory swapping (should be 0)
4. Slow queries (use `SLOWLOG`)

**Solutions**:
- Enable pipelining in clients
- Optimize key patterns (avoid `KEYS *`)
- Use connection pooling
- Scale horizontally (add nodes)

### Memory Issues

**Check**:
- `redis_memory_fragmentation_ratio` > 1.5
- Evictions occurring (`redis_evicted_keys_total`)

**Solutions**:
- Restart Redis to defragment
- Enable `activedefrag`
- Increase `maxmemory`
- Optimize data structures (use hashes for small objects)

### Connection Exhaustion

**Check**:
- `redis_rejected_connections_total`
- `envoy_cluster_upstream_cx_overflow`

**Solutions**:
- Increase `maxclients` in Redis
- Increase circuit breaker limits in Envoy
- Use connection pooling in applications
- Scale Envoy horizontally

---

## Production Checklist

- [ ] Kernel parameters tuned (`optimize-kernel.sh` executed)
- [ ] THP disabled
- [ ] File descriptor limits increased
- [ ] Redis `maxmemory` configured appropriately
- [ ] AOF rewrite thresholds optimized
- [ ] Envoy circuit breakers tuned for workload
- [ ] Monitoring dashboards configured
- [ ] Baseline benchmark results documented
- [ ] Alerting rules configured for key metrics
- [ ] Backup strategy tested under load

---

## Additional Resources

- [Redis Optimization Tips](https://redis.io/topics/optimization)
- [Envoy Performance Best Practices](https://www.envoyproxy.io/docs/envoy/latest/faq/performance/overview)
- [Linux Networking Tuning](https://www.kernel.org/doc/Documentation/networking/scaling.txt)
