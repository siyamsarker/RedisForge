# RedisForge - Production-Ready Envoy Proxy Dockerfile
# Optimized for Redis cluster proxy handling millions of requests per minute

FROM envoyproxy/envoy:v1.32-latest

LABEL maintainer="RedisForge Team"
LABEL description="Production-optimized Envoy proxy for Redis cluster management and routing"
LABEL version="1.0.0"

# Install required dependencies for monitoring, debugging, and operations
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    bash \
    ca-certificates \
    dumb-init \
    procps \
    net-tools \
    dnsutils \
    iputils-ping \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories with proper permissions
RUN mkdir -p /etc/envoy /etc/envoy/templates /var/log/envoy /var/run/envoy /etc/envoy/certs \
    && chmod 755 /etc/envoy /var/log/envoy /var/run/envoy

# Copy Envoy configuration template
COPY config/envoy/envoy.yaml /etc/envoy/templates/envoy.yaml
RUN chmod 644 /etc/envoy/templates/envoy.yaml

# Copy entrypoint
COPY docker/envoy/entrypoint.sh /usr/local/bin/redisforge-envoy-entrypoint.sh
RUN chmod +x /usr/local/bin/redisforge-envoy-entrypoint.sh

# Create health check script for container orchestration
RUN echo '#!/bin/bash' > /usr/local/bin/healthcheck.sh && \
    echo 'curl -sf http://localhost:9901/ready > /dev/null' >> /usr/local/bin/healthcheck.sh && \
    chmod +x /usr/local/bin/healthcheck.sh

# Expose ports:
# 6379 - Redis proxy port (client connections)
# 9901 - Admin interface
# 9902 - Prometheus metrics endpoint
EXPOSE 6379 9901 9902

# Set working directory
WORKDIR /etc/envoy

# Health check
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# Default command with service cluster and node identification
CMD ["envoy", "-c", "/etc/envoy/envoy.yaml", "--service-cluster", "redis-cluster-proxy", "--service-node", "envoy-redis-proxy", "--log-level", "info"]

# Security: Run as envoy user (created in base image)
USER envoy

# Entrypoint performs templating then execs Envoy
ENTRYPOINT ["/usr/local/bin/redisforge-envoy-entrypoint.sh"]

# Volume for TLS certificates (mounted at runtime)
VOLUME ["/etc/envoy/certs"]

