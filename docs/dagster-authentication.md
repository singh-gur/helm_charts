# Dagster Authentication Setup

Dagster OSS does not have built-in authentication. This guide shows how to add authentication using Caddy, OAuth2 Proxy, and Zitadel.

## Architecture

```
User → Caddy (Firewall) → OAuth2 Proxy → Zitadel Auth → Traefik Ingress → Dagster
```

## Prerequisites

- Caddy reverse proxy running on firewall
- Traefik ingress controller in Kubernetes
- Zitadel instance at `https://auth.gsingh.io`
- Docker on firewall (for OAuth2 Proxy)

## Setup Instructions

### 1. Create Zitadel Application

1. Login to Zitadel at `https://auth.gsingh.io`
2. Navigate to your project
3. Create new application:
   - **Name**: Dagster
   - **Type**: Web Application
   - **Authentication Method**: Code (with PKCE)
   - **Redirect URIs**: `https://dagster.gsingh.io/oauth2/callback`
   - **Post Logout URIs**: `https://dagster.gsingh.io`
4. Save and note the **Client ID** and **Client Secret**

### 2. Deploy OAuth2 Proxy on Firewall

Create directory structure:
```bash
mkdir -p /opt/oauth2-proxy
cd /opt/oauth2-proxy
```

Create `docker-compose.yml`:
```yaml
version: '3.8'

services:
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:latest
    container_name: oauth2-proxy-dagster
    restart: unless-stopped
    command:
      - --config=/oauth2-proxy.cfg
    volumes:
      - ./oauth2-proxy.cfg:/oauth2-proxy.cfg:ro
    ports:
      - "127.0.0.1:4180:4180"
    environment:
      - OAUTH2_PROXY_CLIENT_ID=${ZITADEL_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${ZITADEL_CLIENT_SECRET}
      - OAUTH2_PROXY_COOKIE_SECRET=${COOKIE_SECRET}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

Create `oauth2-proxy.cfg`:
```ini
# Provider Configuration
provider = "oidc"
provider_display_name = "Zitadel SSO"
oidc_issuer_url = "https://auth.gsingh.io"
redirect_url = "https://dagster.gsingh.io/oauth2/callback"

# Email/Domain Configuration
email_domains = ["*"]

# Cookie Configuration
cookie_name = "_oauth2_proxy_dagster"
cookie_domains = [".gsingh.io"]
cookie_secure = true
cookie_httponly = true
cookie_samesite = "lax"

# Session Configuration
session_store_type = "cookie"
session_cookie_minimal = true

# Upstream Configuration
upstreams = ["http://static://200"]
http_address = "0.0.0.0:4180"

# Logging
request_logging = true
auth_logging = true
standard_logging = true

# Security
skip_provider_button = true
```

Create `.env` file:
```bash
# From Zitadel application
ZITADEL_CLIENT_ID=your_client_id_here
ZITADEL_CLIENT_SECRET=your_client_secret_here

# Generate with: python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
COOKIE_SECRET=your_generated_cookie_secret_here
```

Generate cookie secret:
```bash
python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
```

Start OAuth2 Proxy:
```bash
docker-compose up -d
docker-compose logs -f
```

### 3. Configure Caddy

Add to your Caddyfile:
```caddy
# OAuth2 Auth snippet for reuse
(oauth2_auth) {
    forward_auth localhost:4180 {
        uri /oauth2/auth
        copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Access-Token
    }
}

# Dagster with Zitadel authentication
dagster.gsingh.io {
    # Handle OAuth2 callback and auth endpoints
    handle /oauth2/* {
        reverse_proxy localhost:4180
    }

    # Require authentication for all other paths
    handle {
        import oauth2_auth
        
        # Forward to Traefik ingress in Kubernetes
        # Replace TRAEFIK_INGRESS_IP with your Traefik service IP or LoadBalancer IP
        reverse_proxy https://TRAEFIK_INGRESS_IP {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Forwarded-User {http.request.header.X-Auth-Request-Email}
            
            # If using self-signed certs in K8s
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
}
```

Find your Traefik ingress IP:
```bash
kubectl get svc -n kube-system traefik
# Or if using different namespace:
kubectl get svc -A | grep traefik
```

Reload Caddy:
```bash
caddy reload --config /etc/caddy/Caddyfile
```

### 4. Configure Dagster Ingress

The Dagster Helm chart is already configured with Traefik support in `values.yaml`:

```yaml
dagster:
  enabled: true
  version: 1.12.10
  namespace: dagster
  ingress:
    host: dagster.gsingh.io
    ingressClassName: traefik
    annotations: {}
```

Optional Traefik annotations (uncomment if needed):
```yaml
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
      traefik.ingress.kubernetes.io/router.tls: "true"
```

### 5. Deploy Changes

Commit and push the changes:
```bash
git add charts/root-app/templates/dagster.yaml charts/root-app/values.yaml
git commit -m "feat(dagster): add Traefik ingress and authentication support"
git push
```

ArgoCD will automatically sync and apply the changes.

### 6. Verify Setup

1. **Check OAuth2 Proxy logs**:
   ```bash
   docker logs -f oauth2-proxy-dagster
   ```

2. **Test authentication flow**:
   - Visit `https://dagster.gsingh.io`
   - You should be redirected to Zitadel login
   - After successful login, you'll be redirected back to Dagster
   - Check browser cookies for `_oauth2_proxy_dagster`

3. **Check Dagster pods**:
   ```bash
   kubectl get pods -n dagster
   kubectl logs -n dagster -l app.kubernetes.io/component=dagster-webserver
   ```

## Troubleshooting

### OAuth2 Proxy Issues

**Check logs**:
```bash
docker logs oauth2-proxy-dagster
```

**Common issues**:
- Invalid client credentials: Verify `ZITADEL_CLIENT_ID` and `ZITADEL_CLIENT_SECRET`
- Redirect URI mismatch: Ensure Zitadel app has `https://dagster.gsingh.io/oauth2/callback`
- Cookie issues: Verify `cookie_domains` includes `.gsingh.io`

### Caddy Issues

**Test OAuth2 Proxy directly**:
```bash
curl -I http://localhost:4180/oauth2/auth
# Should return 401 or redirect
```

**Check Caddy logs**:
```bash
journalctl -u caddy -f
# Or if running in Docker:
docker logs caddy
```

### Traefik Issues

**Check ingress**:
```bash
kubectl get ingress -n dagster
kubectl describe ingress -n dagster dagster-dagster-webserver
```

**Check Traefik logs**:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

### Authentication Loop

If you get stuck in a redirect loop:
1. Clear browser cookies for `dagster.gsingh.io`
2. Check `redirect_url` in OAuth2 Proxy config matches Zitadel
3. Verify `cookie_domains` is set correctly

## Security Considerations

1. **Cookie Secret**: Keep the `COOKIE_SECRET` secure and rotate periodically
2. **Client Secret**: Store Zitadel client secret securely, never commit to git
3. **HTTPS Only**: Ensure all traffic uses HTTPS (`cookie_secure = true`)
4. **Email Domains**: Consider restricting `email_domains` to your organization
5. **Network Policies**: Add Kubernetes NetworkPolicies to restrict Dagster access

## Alternative: Traefik ForwardAuth Middleware

If you prefer to handle authentication in Kubernetes instead of at the firewall, see the Traefik ForwardAuth middleware approach in the main documentation.

## References

- [OAuth2 Proxy Documentation](https://oauth2-proxy.github.io/oauth2-proxy/)
- [Zitadel OIDC Documentation](https://zitadel.com/docs/guides/integrate/login/oidc)
- [Caddy Forward Auth](https://caddyserver.com/docs/caddyfile/directives/forward_auth)
- [Traefik ForwardAuth Middleware](https://doc.traefik.io/traefik/middlewares/http/forwardauth/)
