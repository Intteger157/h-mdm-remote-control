# Single port 443 + unified certbot (Example)

Automates what you configured manually:

- **Host nginx `stream`** — SNI on `:443` → Remote (`9443`) + MDM (`8443`)
- **Host nginx `:80`** — HTTP-01 for **both** domains via **certbot**
- **Weekly cron** — renew + sync certs into Docker volumes
- **MDM compose patch** — `443:8443` → `127.0.0.1:8443:8443`, certbot off public `:80`
- **Remote nginx** — public `:80` moved to `127.0.0.1:8080` so host nginx owns ACME

## Prerequisites

- Headwind Remote installed (`sudo ./install.sh`) with `web_https_port: 9443` in `config.yaml`
- Headwind MDM Docker at `HMDM_DOCKER_DIR` (default `/root/hmdm-docker`)
- DNS: `REMOTE_DOMAIN` and `MDM_DOMAIN` → this server
- Firewall: `443/tcp`, `80/tcp`, `8089/tcp`, `8989/tcp`, `10000-10500/udp`

## Quick start

```bash
cd ~/h-mdm-remote-control
git pull

cp scripts/single-port/config.env.example scripts/single-port/config.env
nano scripts/single-port/config.env   # domains, paths, email

chmod +x scripts/single-port/*.sh
sudo scripts/single-port/setup-single-port.sh
```

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

Adjust `HMDM_LETSENCRYPT_DIR` if your MDM stores certs elsewhere (`find /root/hmdm-docker -name fullchain.pem`).

## Already configured manually?

If SNI + nginx stream already work, run renewal once — it will **issue** missing host certs and **renew** existing ones:

```bash
cp scripts/single-port/config.env.example scripts/single-port/config.env
nano scripts/single-port/config.env
chmod +x scripts/single-port/renew-certificates.sh
sudo scripts/single-port/renew-certificates.sh   # test once
sudo certbot certificates   # must list REMOTE_DOMAIN and MDM_DOMAIN
```

Cron (weekly):

```bash
echo '0 4 * * 1 root /root/h-mdm-remote-control/scripts/single-port/renew-certificates.sh >> /var/log/headwind-cert-renew.log 2>&1' | sudo tee /etc/cron.d/headwind-cert-renew
```

**Important:** `certbot certificates` on the **host** must show both `REMOTE_DOMAIN` and `MDM_DOMAIN`. If you only see unrelated certs (e.g. `webjson.*`), renewal cannot protect Remote/MDM until host certbot issues them (port 80 ACME). The script installs `headwind-acme.conf` automatically if missing.

If certs exist only in Docker volumes and sites still work, do **not** panic — sync is skipped until host certs exist. Then run `renew-certificates.sh` again after successful issuance.

## Renewal

Automatic: `/etc/cron.d/headwind-cert-renew` — **Mondays 04:00**.

Manual:

```bash
sudo ~/h-mdm-remote-control/scripts/single-port/renew-certificates.sh
sudo certbot certificates
```

Logs: `/var/log/headwind-cert-renew.log`

## What the script does

1. Installs `nginx`, `libnginx-mod-stream`, `certbot`
2. Writes `/etc/nginx/stream.d/headwind-sni-443.conf`
3. Writes `/etc/nginx/sites-enabled/headwind-acme.conf` (port 80 ACME)
4. Patches MDM `docker-compose.yaml` (backup with `.bak.single-port-*`)
5. Stops Remote docker `:80`, patches Remote nginx to `127.0.0.1:8080`
6. Issues/renews certs, `rsync` to Remote `deploy/dist/ssl` and MDM letsencrypt volume
7. Reloads Remote nginx + MDM container

## After setup

MDM plugin URL:

```
https://REMOTE_DOMAIN/web-admin/
```

Secret: `cat deploy/dist/credentials/janus_api_secret`

## Rollback

```bash
sudo systemctl stop nginx
# restore MDM compose from backup in HMDM_DOCKER_DIR
cd /root/hmdm-docker && docker compose up -d
# restore Remote nginx listen 80 if needed, re-run remote install playbooks
```

## Notes

- SNI passthrough keeps **separate certificates** on each backend; host certbot copies LE files into Docker volumes so backends reload valid certs.
- If MDM cert path differs, fix `HMDM_LETSENCRYPT_DIR` before running setup.
- **Do not** run Remote docker `certbot` service on public `:80` after setup — host certbot owns port 80.
