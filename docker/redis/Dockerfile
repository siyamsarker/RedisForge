# RedisForge - Production-Ready Redis 8.2 OSS Dockerfile
# Optimized for high-throughput distributed systems handling millions of requests/min

FROM redis:8.2-alpine

LABEL maintainer="RedisForge Team"
LABEL description="Production-optimized Redis 8.2 OSS for distributed cluster deployment"
LABEL version="1.0.0"

# Install required dependencies for production monitoring and debugging
RUN apk add --no-cache \
    bash \
    curl \
    ca-certificates \
    tzdata \
    tini \
    procps \
    net-tools \
    && rm -rf /var/cache/apk/*

# Create redis user and necessary directories with proper permissions
RUN mkdir -p /data /etc/redis /var/log/redis /var/run/redis \
    && chown -R redis:redis /data /etc/redis /var/log/redis /var/run/redis \
    && chmod 755 /data /etc/redis /var/log/redis /var/run/redis

# Copy configuration files
COPY --chown=redis:redis config/redis/redis.conf /etc/redis/redis.conf
COPY --chown=redis:redis config/redis/users.acl /etc/redis/users.acl

# Set proper permissions for security
RUN chmod 644 /etc/redis/redis.conf \
    && chmod 600 /etc/redis/users.acl

# Create health check script
RUN echo '#!/bin/sh' > /usr/local/bin/healthcheck.sh && \
    echo 'redis-cli -h localhost -p ${REDIS_PORT:-6379} ${REDIS_PASSWORD:+-a $REDIS_PASSWORD} ping | grep -q PONG' >> /usr/local/bin/healthcheck.sh && \
    chmod +x /usr/local/bin/healthcheck.sh

# Expose Redis ports (main, cluster bus)
EXPOSE 6379 16379

# Set working directory
WORKDIR /data

# Use tini for proper signal handling and zombie reaping
ENTRYPOINT ["/sbin/tini", "--"]

# Health check for container orchestration
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# Default command (can be overridden via docker run)
CMD ["redis-server", "/etc/redis/redis.conf"]

# Security best practices: run as non-root
USER redis

# Volumes for persistent data
VOLUME ["/data", "/var/log/redis"]

