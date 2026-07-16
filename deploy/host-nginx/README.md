# Single port 443: MDM + Headwind Remote on one VPS

When Headwind MDM already binds **host port 443**, requests to `https://remote.example.com/web-admin/` hit **Tomcat (MDM)** and return HTTP 404.

Headwind Remote listens on **`web_https_port`** from `config.yaml` (typically **9443** when MDM uses 443).

## Quick check (works now)

```bash
curl -kI https://remote.example.com:9443/web-admin/
```

MDM plugin URL: `https://remote.example.com:9443/web-admin/`

---

## Single port 443 (SNI routing)

Use **host nginx** in `stream` mode with `ssl_preread` — TLS is terminated by each backend (MDM and Remote keep their own certificates).

```
Internet :443
       │
  host nginx (stream, ssl_preread)
       │
       ├── remote.example.com ──► 127.0.0.1:9443  (Remote docker nginx)
       └── mdm.example.com    ──► 127.0.0.1:8443  (MDM docker Tomcat)
```

### Step 1 — Free port 443 on MDM

In `/root/hmdm-docker/docker-compose.yaml` (or your MDM compose file), change MDM publish:

```yaml
# before
ports:
  - "443:8443"

# after — only localhost, not public 443
ports:
  - "127.0.0.1:8443:8443"
```

Apply:

```bash
cd /root/hmdm-docker   # your MDM docker path
docker compose down
docker compose up -d
```

Verify MDM is **not** on public 443:

```bash
ss -tlnp | grep ':443'
# should NOT show hmdm-docker on 0.0.0.0:443
```

### Step 2 — Confirm Remote on 9443

In `~/h-mdm-remote-control/config.yaml`:

```yaml
hostname: "remote.example.com"
email: "admin@example.com"
web_https_port: 9443
```

Re-apply if you changed it:

```bash
cd ~/h-mdm-remote-control
sudo ansible-playbook deploy/pre_apuppet.yaml
sudo ansible-playbook deploy/start.yaml
```

Test backend directly:

```bash
curl -kI https://127.0.0.1:9443/web-admin/ --resolve remote.example.com:9443:127.0.0.1
```

### Step 3 — Install host nginx (SNI proxy)

```bash
sudo apt install -y nginx
sudo mkdir -p /etc/nginx/stream.d
```

Copy `deploy/host-nginx/sni-443.conf` from this repo to `/etc/nginx/stream.d/sni-443.conf`.

Edit `/etc/nginx/nginx.conf` — add **inside** the top-level context (same level as `http {`):

```nginx
stream {
    include /etc/nginx/stream.d/*.conf;
}
```

Enable and test:

```bash
sudo nginx -t
sudo systemctl enable --now nginx
ss -tlnp | grep ':443'
# should show nginx on 0.0.0.0:443
```

### Step 4 — Verify in browser

| URL | Expected |
|-----|----------|
| `https://remote.example.com/web-admin/` | Headwind Remote UI |
| `https://mdm.example.com/` | Headwind MDM |

Both without `:9443` in the URL.

### Step 5 — MDM plugin URL (after SNI)

```
https://remote.example.com/web-admin/
```

Secret: `cat ~/h-mdm-remote-control/deploy/dist/credentials/janus_api_secret`

---

## SSL certificates

Remote install already issued Let's Encrypt cert via docker certbot into:

```
~/h-mdm-remote-control/deploy/dist/ssl/live/remote.example.com/
```

MDM uses its own cert inside the MDM container / your MDM setup.

SNI passthrough does **not** require a new combined certificate on host nginx — each backend presents its own cert.

Port **80** stays with Remote docker nginx for cert renewal (ACME HTTP-01). Do not bind host nginx to :80 unless you merge ACME routing too.

---

## Firewall

Keep open:

- `443/tcp` — public HTTPS (host nginx → SNI)
- `80/tcp` — Let's Encrypt renewal (Remote nginx)
- `8089/tcp`, `8989/tcp` — Janus
- `10000-10500/udp` — WebRTC

You can close public `9443` after SNI works (optional hardening).

---

## Rollback

1. Stop host nginx: `sudo systemctl stop nginx`
2. Restore MDM ports: `"443:8443"` in hmdm-docker compose
3. `docker compose up -d` in hmdm-docker
