# Monitoring Setup Guide

This guide explains how to set up monitoring for your RedisForge cluster using Prometheus and Grafana.

## Architecture

RedisForge exposes metrics at three levels:
1. **Redis Metrics**: Via `redis_exporter` (default port 9121)
2. **System Metrics**: Via `node_exporter` (default port 9100)
3. **Proxy Metrics**: Via Envoy's admin interface (default port 9901)

## Prerequisites

- A running Prometheus server
- A running Grafana instance
- Network access from Prometheus to your RedisForge nodes

## Prometheus Configuration

Add the following scrape configs to your `prometheus.yml`:

```yaml
scrape_configs:
  # Scrape Redis Exporters
  - job_name: 'redis_exporter'
    static_configs:
      - targets:
        - 'redis-node-1:9121'
        - 'redis-node-2:9121'
        - 'redis-node-3:9121'
        # Add all your nodes here

  # Scrape Node Exporters
  - job_name: 'node_exporter'
    static_configs:
      - targets:
        - 'redis-node-1:9100'
        - 'redis-node-2:9100'
        - 'redis-node-3:9100'

  # Scrape Envoy Proxy
  - job_name: 'envoy'
    metrics_path: /stats/prometheus
    static_configs:
      - targets: ['envoy-host:9901']
```

## Grafana Dashboard

We provide a pre-configured Grafana dashboard in `monitoring/grafana/dashboards/redisforge-dashboard.json`.

### Import Instructions

1. Log in to your Grafana instance
2. Go to **Dashboards** -> **New** -> **Import**
3. Upload the JSON file or paste its contents
4. Select your Prometheus data source
5. Click **Import**

### Key Metrics to Watch

- **Cluster State**: Should always be `ok`
- **Connected Clients**: Watch for sudden spikes
- **Command Latency**: High latency indicates performance issues
- **Memory Fragmentation**: If > 1.5, consider running active defragmentation
- **Envoy Upstream Health**: Ensure all upstream hosts are healthy

## Alerting Rules

Recommended Prometheus alerting rules:

```yaml
groups:
- name: RedisAlerts
  rules:
  - alert: RedisDown
    expr: redis_up == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Redis instance {{ $labels.instance }} is down"

  - alert: ClusterStateFail
    expr: redis_cluster_state == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Redis Cluster state is FAIL"

  - alert: HighMemoryUsage
    expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Redis memory usage > 90%"
```
