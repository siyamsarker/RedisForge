# Operations Runbook

This runbook documents common operational tasks for maintaining a RedisForge cluster.

## Table of Contents

- [Cluster Management](#cluster-management)
- [Scaling](#scaling)
- [Backups & Restore](#backups--restore)
- [Troubleshooting](#troubleshooting)
- [Upgrades](#upgrades)

## Cluster Management

### Check Cluster Health

```bash
# Connect to any node
redis-cli -h <node-ip> -p 6379 -a $REDIS_REQUIREPASS cluster info
```

**Expected Output:**
- `cluster_state:ok`
- `cluster_slots_assigned:16384`
- `cluster_known_nodes:6` (for a 3-master, 3-replica setup)

### Failover Test

To test automatic failover, crash a master node:

```bash
# On the master node host
docker stop redis-master
```

**Verify:**
1. Check `cluster nodes` on another node.
2. Ensure a replica has been promoted to master.
3. Restart the stopped node; it should rejoin as a replica.

## Scaling

### Adding a Node

Use the `scale.sh` script:

```bash
# Add a new master
./scripts/scale.sh add <new-node-ip>:6379 --role master

# Add a new replica
./scripts/scale.sh add <new-node-ip>:6379 --role replica --replica-of <master-id>
```

### Removing a Node

```bash
./scripts/scale.sh remove <node-id>
```

## Backups & Restore

### Trigger Manual Backup

```bash
./scripts/backup.sh
```

### Restore from Backup

1. Stop all Redis nodes.
2. Clean data directories (`rm -rf data/redis/*`).
3. Download backup archive from S3.
4. Extract AOF files to data directories.
5. Start Redis nodes.
6. If IP addresses changed, you may need to recreate the cluster config (`nodes.conf`).

## Troubleshooting

### "CLUSTERDOWN Hash slot not served"

**Cause:** Not all 16384 slots are covered by master nodes.
**Fix:**
1. Check `cluster nodes` to see which slots are missing.
2. If a node failed, bring it back up.
3. If data loss occurred, run `redis-cli --cluster fix`.

### "MOVED" Errors in Application

**Cause:** Client is connecting to the wrong node and not handling redirects.
**Fix:**
1. Ensure application uses a Redis Cluster-aware client.
2. Or use Envoy Proxy (RedisForge default) which handles redirects transparently.

## Upgrades

### Upgrade Redis Version

1. Update `REDIS_VERSION` in `.env`.
2. Update `docker/redis/Dockerfile`.
3. Perform rolling restart:
   - Stop one replica.
   - Rebuild/pull new image.
   - Start replica.
   - Failover master to this replica.
   - Repeat for all nodes.

### Upgrade Envoy

1. Update `ENVOY_VERSION` in `.env`.
2. Update `docker/envoy/Dockerfile`.
3. Redeploy Envoy container:
   ```bash
   ./scripts/deploy.sh envoy
   ```
