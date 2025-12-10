# Docker Deployment with nginx-proxy and SSL

This guide documents how to deploy dlcenter with nginx-proxy, Let's Encrypt SSL certificates, and WebSocket support.

## Architecture

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│   nginx-proxy       │◄────│  acme-companion     │     │     dlcenter        │
│  (reverse proxy)    │     │  (SSL certificates) │     │   (application)     │
│  ports 80, 443      │     │                     │     │                     │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘
```

## Prerequisites

Create a Docker network for all containers:

```bash
docker network create nginx-proxy-network
```

## 1. nginx-proxy

The reverse proxy that routes traffic to containers based on `VIRTUAL_HOST`.

```bash
docker run -d \
  --name nginx-proxy \
  --restart always \
  --network nginx-proxy-network \
  -p 80:80 \
  -p 443:443 \
  -v certs:/etc/nginx/certs:ro \
  -v html:/usr/share/nginx/html \
  -v vhostd:/etc/nginx/vhost.d \
  -v /var/run/docker.sock:/tmp/docker.sock:ro \
  -e ENABLE_HTTP2=false \
  nginxproxy/nginx-proxy:1.9
```

**Notes:**
- `ENABLE_HTTP2=false` is required for WebSocket support
- Shared volumes (`certs`, `html`, `vhostd`) are used by acme-companion

## 2. acme-companion (Let's Encrypt)

Automatically creates and renews SSL certificates.

```bash
docker run -d \
  --name nginx-proxy-acme \
  --restart always \
  --network nginx-proxy-network \
  -v certs:/etc/nginx/certs:rw \
  -v html:/usr/share/nginx/html \
  -v acme:/etc/acme.sh \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e DEFAULT_EMAIL=your-email@example.com \
  -e NGINX_PROXY_CONTAINER=nginx-proxy \
  nginxproxy/acme-companion
```

**Notes:**
- `NGINX_PROXY_CONTAINER=nginx-proxy` tells the companion which container to work with
- Certificates are stored in the `certs` volume and auto-renewed

## 3. dlcenter Application

```bash
docker run -d \
  --name dlcenter \
  --restart always \
  --network nginx-proxy-network \
  -e VIRTUAL_HOST=dl.center \
  -e LETSENCRYPT_HOST=dl.center \
  -e LETSENCRYPT_EMAIL=your-email@example.com \
  ghcr.io/simkim/dlcenter:latest
```

**Notes:**
- `VIRTUAL_HOST` tells nginx-proxy to route traffic for this domain
- `LETSENCRYPT_HOST` tells acme-companion to request a certificate for this domain

## 4. WebSocket Configuration

WebSocket support requires additional nginx configuration. After starting the containers, create the vhost configuration:

```bash
docker exec nginx-proxy sh -c 'cat > /etc/nginx/vhost.d/dl.center_location << EOF
proxy_http_version 1.1;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection "Upgrade";
proxy_read_timeout 86400;
EOF'

docker exec nginx-proxy nginx -s reload
```

This configuration:
- Enables HTTP/1.1 for the upstream connection (required for WebSocket upgrade)
- Passes the `Upgrade` and `Connection` headers to the backend
- Sets a long read timeout for persistent WebSocket connections

## Volumes

| Volume | Purpose |
|--------|---------|
| `certs` | SSL certificates (shared between nginx-proxy and acme-companion) |
| `html` | ACME challenge files for Let's Encrypt verification |
| `vhostd` | Custom nginx vhost configurations |
| `acme` | ACME state and account information |

## Verification

Check that SSL is working:

```bash
curl -I https://dl.center
```

Test WebSocket connectivity:

```bash
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: test" \
  -H "Sec-WebSocket-Version: 13" \
  https://dl.center/ws
```

Expected response: `HTTP/1.1 101 Switching Protocols`

## Troubleshooting

### Certificate not issued

Check acme-companion logs:

```bash
docker logs nginx-proxy-acme
```

Ensure:
- DNS is pointing to the server
- Port 80 is accessible (for HTTP-01 challenge)

### WebSocket not working

1. Verify HTTP/2 is disabled: response should show `HTTP/1.1` not `HTTP/2`
2. Check the vhost location file exists:
   ```bash
   docker exec nginx-proxy cat /etc/nginx/vhost.d/dl.center_location
   ```
3. Reload nginx after changes:
   ```bash
   docker exec nginx-proxy nginx -s reload
   ```

### Container can't connect to nginx-proxy

Ensure all containers are on the same network:

```bash
docker network inspect nginx-proxy-network
```
