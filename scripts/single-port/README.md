# Single port 443 + unified certbot via HAProxy

**Edge:** HAProxy terminates TLS on `:443`, routes by `Host`, injects **real client IP**
(`X-Real-IP` / `X-Forwarded-For`) into MDM and Remote backends.

```
Internet :443
       │
  HAProxy (SSL terminate)
       │
       ├── Host: remote.* ──► https://127.0.0.1:9443  (Remote docker nginx)
       └── Host: mdm.*    ──► https://127.0.0.1:8443  (MDM docker Tomcat)
```

Also:

- **HAProxy `:80`** — HTTP-01 for both domains + redirect to HTTPS
- **Weekly cron** — renew + rebuild HAProxy PEM bundles + sync into Docker volumes
- **MDM compose** — public ports → `127.0.0.1:8443` / `127.0.0.1:8081`
- **Remote nginx** — public `:80` → `127.0.0.1:8080`; `set_real_ip_from 127.0.0.1`
- **Host nginx** — disabled (no more `stream` SNI)

## Prerequisites

- Headwind Remote installed (`sudo ./install.sh`) with `web_https_port: 9443` and ideally
  `web_http_listen: "127.0.0.1:8080"` in `config.yaml`
- Headwind MDM Docker at `HMDM_DOCKER_DIR` (default `/root/hmdm-docker`)
- DNS: `REMOTE_DOMAIN` and `MDM_DOMAIN` → this server
- Firewall: `443/tcp`, `80/tcp`, `8089/tcp`, `8989/tcp`, `10000-10500/udp`

## Quick start (new host)

```bash
cd ~/h-mdm-remote-control
git pull

cp scripts/single-port/config.env.example scripts/single-port/config.env
nano scripts/single-port/config.env

chmod +x scripts/single-port/*.sh
sudo scripts/single-port/setup-single-port.sh
```

## Migrate from nginx stream (production)

If you already run `stream.d/sni-443.conf` / `headwind-acme.conf`:

```bash
cd ~/h-mdm-remote-control
git pull
cp -n scripts/single-port/config.env.example scripts/single-port/config.env
# ensure config.env matches your domains/paths
chmod +x scripts/single-port/*.sh
sudo scripts/single-port/migrate-nginx-to-haproxy.sh
```

This stops/disables host nginx, installs HAProxy, reuses existing Let's Encrypt certs,
patches MDM `proxy.addresses`, and reloads services.

## Config (`config.env`)

| Variable | Example |
|----------|---------|
| `REMOTE_DOMAIN` | `remote.example.com` |
| `MDM_DOMAIN` | `mdm.example.com` |
| `CERTBOT_EMAIL` | `admin@example.com` |
| `REMOTE_HTTPS_PORT` | `9443` |
| `MDM_HTTPS_PORT` | `8443` |
| `REMOTE_DIR` | `/root/h-mdm-remote-control` |
| `HMDM_DOCKER_DIR` | `/root/hmdm-docker` |
| `HMDM_LETSENCRYPT_DIR` | `/root/hmdm-docker/volumes/letsencrypt` |

## Renewal

Automatic: `/etc/cron.d/headwind-cert-renew` — Mondays 04:00.

Manual:

```bash
sudo ~/h-mdm-remote-control/scripts/single-port/renew-certificates.sh
sudo certbot certificates
ls -la /etc/haproxy/certs/
```

Logs: `/var/log/headwind-cert-renew.log`

## What setup does

1. Installs `haproxy`, `certbot`
2. Disables host nginx edge
3. Writes `/etc/haproxy/haproxy.cfg` + PEM bundles in `/etc/haproxy/certs/`
4. Patches MDM compose + `context.xml` (`proxy.addresses=127.0.0.1`, `proxy.ip.header=X-Real-IP`)
5. Moves Remote docker `:80` to `127.0.0.1:8080`
6. Syncs LE certs into Remote/MDM volumes; weekly cron

## Verify client IP

After a device sync, **Devices → IP** should show the public/NAT address of the phone
(or office NAT), **not** `172.18.0.1`.

```bash
curl -I https://mdm.example.com/
# On MDM: after sync, IP column updates
```

## Rollback to nginx stream (legacy)

```bash
sudo systemctl disable --now haproxy
sudo systemctl enable --now nginx
# restore stream + acme configs from git templates if removed
sudo cp scripts/single-port/templates/sni-443.conf.template /etc/nginx/stream.d/headwind-sni-443.conf
# re-render domains, ensure nginx stream include, nginx -t && systemctl restart nginx
```

Legacy templates remain in `templates/sni-443.conf.template` and `acme-http.conf.template`.

## Notes

- Backends keep their own TLS (HAProxy re-encrypts to `127.0.0.1`).
- **MDM Tomcat** still needs an **RSA** Let's Encrypt cert for `hmdm.jks`.
- Do not run Remote docker `certbot` on public `:80` after setup.
- Janus stays on `8089` / `8989` (not through HAProxy).

## Troubleshooting

### HAProxy fails to start (no certs)

```bash
ls /etc/letsencrypt/live/
sudo scripts/single-port/renew-certificates.sh
ls /etc/haproxy/certs/
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

### Still seeing 172.18.0.1

1. Confirm HAProxy is on `:443` (`ss -tlnp | grep 443`)
2. Confirm nginx is **not** listening on `:443`
3. Confirm MDM `context.xml` has `proxy.addresses=127.0.0.1` and `proxy.ip.header=X-Real-IP`
4. Restart MDM: `cd /root/hmdm-docker && docker compose restart hmdm`
5. Force device config sync

### MDM SSL / Tomcat

```bash
curl -kI https://127.0.0.1:8443/ --resolve mdm.example.com:8443:127.0.0.1
sudo certbot certonly --webroot -w /var/www/letsencrypt/mdm \
  -d mdm.example.com --cert-name mdm.example.com \
  --key-type rsa --force-renewal \
  --email admin@example.com --agree-tos --non-interactive
sudo ~/h-mdm-remote-control/scripts/single-port/renew-certificates.sh
```
