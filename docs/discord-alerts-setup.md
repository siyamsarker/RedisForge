# RedisForge - Discord Alerts Setup Guide

**💬 Configure Discord webhook notifications for Push Gateway monitoring alerts**

> 👈 **Back to**: [Main README](../README.md) | **Related**: [Quick Start](./quickstart.md) | [Monitoring Troubleshooting](./monitoring-troubleshooting.md)

This guide shows you how to receive Push Gateway alerts in Discord.

---

## 🎯 Overview

All Push Gateway-related alerts will be sent to your Discord channel:
- ✅ **MetricsPushDelayed** - Metrics haven't been pushed recently
- ✅ **PushGatewayDown** - Push Gateway is unreachable
- ✅ **NoMetricsReceived** - No metrics from cluster
- ✅ **MetricsPushServiceDown** - Push service not running
- ✅ **PushGatewayHighMemory** - Memory usage > 512MB

---

## 📝 Step 1: Create Discord Webhook

### Option A: Using Discord Desktop/Web App

1. **Open your Discord server**
2. **Go to Server Settings** (gear icon next to server name)
3. Click **Integrations** in the left sidebar
4. Click **Webhooks** (or View Webhooks)
5. Click **New Webhook** button
6. **Configure the webhook:**
   - **Name**: `RedisForge Alerts` (or your preferred name)
   - **Channel**: Select your alerts channel (e.g., `#alerts`, `#monitoring`, `#ops`)
   - **Icon**: Optional - upload a custom icon
7. Click **Copy Webhook URL**
8. **Save Changes**

### Option B: Using Channel Settings

1. **Right-click on your channel** (e.g., `#alerts`)
2. Click **Edit Channel**
3. Go to **Integrations** tab
4. Click **Webhooks** → **New Webhook**
5. Follow steps 6-8 above

### Your Webhook URL Format

```
https://discord.com/api/webhooks/<webhook_id>/<webhook_token>
```

**Example:**
```
https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ
```

⚠️ **Keep this URL secret!** Anyone with this URL can post to your channel.

---

## 🔧 Step 2: Configure Alertmanager

### Edit alertmanager.yml

Open `/Users/siyam/Desktop/Work Dir/RedisForge/monitoring/alertmanager/alertmanager.yml` and replace all instances of `<YOUR_DISCORD_WEBHOOK_URL>` with your actual webhook URL.

**Before:**
```yaml
- url: '<YOUR_DISCORD_WEBHOOK_URL>/slack'
```

**After:**
```yaml
- url: 'https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ/slack'
```

⚠️ **Important:** Add `/slack` at the end of the URL for Discord compatibility!

### Quick Replace Command

```bash
cd /Users/siyam/Desktop/Work\ Dir/RedisForge

# Replace with your actual webhook URL
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"

# Update the file
sed -i.bak "s|<YOUR_DISCORD_WEBHOOK_URL>|${DISCORD_WEBHOOK}|g" monitoring/alertmanager/alertmanager.yml

# Verify changes
grep "discord.com" monitoring/alertmanager/alertmanager.yml
```

---

## 🚀 Step 3: Deploy Alertmanager

### Option A: Using Docker

```bash
# Create Alertmanager container
docker run -d \
  --name alertmanager \
  --restart=always \
  -p 9093:9093 \
  -v $(pwd)/monitoring/alertmanager:/etc/alertmanager \
  prom/alertmanager:latest \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/alertmanager

# Verify it's running
docker ps | grep alertmanager
docker logs alertmanager
```

### Option B: Using Docker Compose (if you have it)

```yaml
# docker-compose.yml (create if needed)
version: '3.8'
services:
  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: always
    ports:
      - "9093:9093"
    volumes:
      - ./monitoring/alertmanager:/etc/alertmanager
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--storage.path=/alertmanager'
```

```bash
docker-compose up -d alertmanager
```

---

## 🔗 Step 4: Connect Prometheus to Alertmanager

Edit your Prometheus configuration to send alerts to Alertmanager:

```yaml
# prometheus.yml
alerting:
  alertmanagers:
  - static_configs:
    - targets:
      - 'localhost:9093'  # Alertmanager address

rule_files:
  - /etc/prometheus/rules/push-gateway-alerts.yml
```

### Copy Alert Rules to Prometheus

```bash
# Copy the alert rules file
sudo mkdir -p /etc/prometheus/rules
sudo cp monitoring/alertmanager/push-gateway-alerts.yml /etc/prometheus/rules/

# Reload Prometheus
curl -X POST http://localhost:9090/-/reload

# Or restart Prometheus
docker restart prometheus
# OR
sudo systemctl restart prometheus
```

---

## 🧪 Step 5: Test Discord Integration

### Test 1: Send Direct Message to Discord

```bash
# Replace with your webhook URL
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN"

# Send test message
curl -X POST "${DISCORD_WEBHOOK}/slack" \
  -H 'Content-Type: application/json' \
  -d '{
    "text": "🧪 **Test Alert from RedisForge**\n\nIf you see this message, Discord integration is working!"
  }'
```

You should see the test message appear in your Discord channel immediately.

### Test 2: Send Test Alert via Alertmanager

```bash
# Send test alert to Alertmanager
curl -XPOST http://localhost:9093/api/v1/alerts -H 'Content-Type: application/json' -d '[
  {
    "labels": {
      "alertname": "TestPushGatewayAlert",
      "severity": "warning",
      "component": "monitoring",
      "cluster": "redisforge"
    },
    "annotations": {
      "summary": "Test Push Gateway alert",
      "description": "This is a test alert to verify Discord integration for Push Gateway monitoring."
    }
  }
]'
```

Check Discord - you should see the alert within 5-10 seconds.

### Test 3: Trigger Real Alert

Temporarily stop the push service to trigger a real alert:

```bash
# Stop push service
sudo systemctl stop redisforge-metrics-push

# Wait 2-3 minutes for alert to fire
# Check Prometheus alerts: http://localhost:9090/alerts

# Restart service
sudo systemctl start redisforge-metrics-push
```

You should receive alerts in Discord when:
1. Alert fires (MetricsPushServiceDown)
2. Alert resolves (when service restarts)

---

## 📊 Step 6: Verify Alert Rules are Active

### Check Prometheus Alerts

```bash
# List all alert rules
curl http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[] | select(.type=="alerting") | {name: .name, state: .state}'

# Check specific Push Gateway alerts
curl http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.name=="push_gateway_alerts")'
```

### Check Alertmanager Status

```bash
# Check Alertmanager is running
curl http://localhost:9093/api/v1/status

# View active alerts
curl http://localhost:9093/api/v1/alerts | jq

# Check Alertmanager configuration
curl http://localhost:9093/api/v1/status | jq '.config'
```

---

## 🎨 Example Discord Alert Messages

### 1. MetricsPushDelayed Alert

```
🔔 MetricsPushDelayed

Status: firing
Severity: warning
Component: monitoring

Summary: Metrics push delayed for redis-exporter on redis-1.example.com
Description: No metrics pushed from redis-1.example.com for over 2 minutes. Check redisforge-metrics-push service.
Runbook: ssh redis-1.example.com && sudo systemctl status redisforge-metrics-push

Started: 2025-10-30 14:35:22 UTC
```

### 2. PushGatewayDown Alert

```
🔔 PushGatewayDown

Status: firing
Severity: critical
Component: monitoring

Summary: Push Gateway is down
Description: Prometheus cannot scrape Push Gateway. Metrics collection is disrupted.
Runbook: Check Push Gateway service: systemctl status pushgateway

Started: 2025-10-30 14:40:15 UTC
```

### 3. PushGatewayHighMemory Alert

```
🔔 PushGatewayHighMemory

Status: firing
Severity: warning
Component: monitoring

Summary: Push Gateway memory usage > 200MB
Description: Push Gateway is consuming 245MB of memory. Consider increasing scrape frequency or investigating metric cardinality.

Started: 2025-10-30 15:10:00 UTC
```

### 4. Alert Resolved

```
🔔 MetricsPushDelayed

Status: resolved
Severity: warning
Component: monitoring

Summary: Metrics push delayed for redis-exporter on redis-1.example.com
Description: No metrics pushed from redis-1.example.com for over 2 minutes. Check redisforge-metrics-push service.

Started: 2025-10-30 14:35:22 UTC
Ended: 2025-10-30 14:38:10 UTC
```

---

## ⚙️ Configuration Options

### Adjust Alert Frequency

In `alertmanager.yml`, you can adjust how often alerts are sent:

```yaml
routes:
  - match:
      component: monitoring
    receiver: 'discord-pushgateway'
    group_wait: 5s        # Wait 5s before sending first alert
    group_interval: 5s    # Wait 5s before sending grouped alerts
    repeat_interval: 4h   # Repeat alert every 4 hours if still active
```

### Create Multiple Discord Channels

You can send different severity alerts to different channels:

```yaml
receivers:
  # Critical alerts → #critical-alerts channel
  - name: 'discord-critical'
    webhook_configs:
      - url: 'https://discord.com/api/webhooks/CRITICAL_WEBHOOK_ID/TOKEN/slack'

  # Warning alerts → #alerts channel  
  - name: 'discord-pushgateway'
    webhook_configs:
      - url: 'https://discord.com/api/webhooks/ALERTS_WEBHOOK_ID/TOKEN/slack'
```

### Silence Alerts

Temporarily silence alerts via Alertmanager UI:

```bash
# Access Alertmanager UI
open http://localhost:9093

# Or via API
curl -XPOST http://localhost:9093/api/v1/silences -d '{
  "matchers": [
    {"name": "alertname", "value": "PushGatewayHighMemory", "isRegex": false}
  ],
  "startsAt": "2025-10-30T14:00:00Z",
  "endsAt": "2025-10-30T16:00:00Z",
  "comment": "Maintenance window",
  "createdBy": "ops-team"
}'
```

---

## 🛡️ Security Best Practices

### 1. Protect Your Webhook URL

```bash
# Don't commit webhook URLs to git
echo "monitoring/alertmanager/alertmanager.yml" >> .gitignore

# Use environment variables (optional)
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
envsubst < alertmanager.yml.template > alertmanager.yml
```

### 2. Regenerate Webhook if Compromised

If your webhook URL is exposed:
1. Go to Discord Server Settings → Integrations → Webhooks
2. Find your webhook
3. Click **Delete Webhook** or **Regenerate** 
4. Create a new webhook
5. Update `alertmanager.yml`

### 3. Limit Channel Access

Create a dedicated `#redisforge-alerts` channel with limited access:
- Only ops/admin roles can view
- Webhook-only posting (disable member messages)

---

## 🔍 Troubleshooting

### Issue: No alerts in Discord

**Check 1: Webhook URL**
```bash
# Test webhook directly
curl -X POST "YOUR_WEBHOOK_URL/slack" \
  -H 'Content-Type: application/json' \
  -d '{"text": "Test"}'
```

**Check 2: Alertmanager logs**
```bash
docker logs alertmanager | grep -i discord
docker logs alertmanager | grep -i error
```

**Check 3: Prometheus → Alertmanager connection**
```bash
# Check Alertmanager is reachable from Prometheus
curl http://localhost:9093/-/ready
```

### Issue: Rate limited by Discord

Discord webhook limits: **30 requests per 60 seconds**

**Solution:**
```yaml
# In alertmanager.yml, increase repeat_interval
repeat_interval: 6h  # Increase from 4h to 6h
```

### Issue: Alert rules not loading

```bash
# Check Prometheus configuration
curl http://localhost:9090/api/v1/status/config | jq '.data.yaml' | grep rule_files

# Check rule file syntax
promtool check rules monitoring/alertmanager/push-gateway-alerts.yml

# View Prometheus logs
docker logs prometheus | grep -i error
```

---

## ✅ Final Verification Checklist

- [ ] Discord webhook created
- [ ] Webhook URL added to `alertmanager.yml` (with `/slack` suffix)
- [ ] Alertmanager container running
- [ ] Alert rules copied to Prometheus
- [ ] Prometheus configured with Alertmanager endpoint
- [ ] Test message sent to Discord successfully
- [ ] Test alert sent via Alertmanager API
- [ ] Real alert triggered and received in Discord
- [ ] Alert resolved message received
- [ ] Webhook URL secured (not in git)

---

## 📚 Additional Resources

- **Discord Webhooks Docs**: https://discord.com/developers/docs/resources/webhook
- **Alertmanager Docs**: https://prometheus.io/docs/alerting/latest/alertmanager/
- **Prometheus Alerting Rules**: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

---

## 📖 Related Documentation

- **[Main README](../README.md)** - Project overview and features
- **[Quick Start Guide](./quickstart.md)** - Production deployment steps
- **[Monitoring Troubleshooting](./monitoring-troubleshooting.md)** - Fix monitoring issues

---

## 📞 Need Help?

- **Monitoring Issues**: See [monitoring-troubleshooting.md](./monitoring-troubleshooting.md)
- **Setup Issues**: See [Quick Start Guide](./quickstart.md)
- **Report Issues**: [GitHub Issues](https://github.com/siyamsarker/RedisForge/issues)

---

<div align="center">

**🎉 Discord Alerts Configured!**

[👈 Back to Main README](../README.md) | [🔧 Troubleshoot Monitoring](./monitoring-troubleshooting.md)

</div>
---

**Need Help?** Check the troubleshooting section in `MONITORING-TROUBLESHOOTING.md`
