# TLS Assets

RedisForge ships with a helper script (`scripts/generate-certs.sh`) that produces self-signed
certificates for local development and integration testing. The generated files live under
`config/tls/dev` (ignored by Git).

For production, generate certificates signed by your internal CA and mount them into the
Envoy container at runtime:

```
/opt/redisforge/config/tls/prod/server.crt -> /etc/envoy/certs/server.crt
/opt/redisforge/config/tls/prod/server.key -> /etc/envoy/certs/server.key
```

Update the following environment variables if you deviate from the defaults:

- `ENVOY_TLS_CERT_PATH`
- `ENVOY_TLS_KEY_PATH`
- `ENVOY_TLS_ENABLED` (must remain `true` in production)

**Never** commit private keys to the repository. The `.gitignore` already blocks typical
certificate extensions, but you are responsible for storing production keys in a secure
location (e.g., AWS Certificate Manager, Vault, or Secrets Manager).
