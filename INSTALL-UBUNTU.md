# Ubuntu 22.04 / 24.04 install notes

Fork: https://github.com/Intteger157/h-mdm-remote-control

This fork modernizes the Headwind Remote installer for **Ubuntu 22.04+** and **Debian 12+** while keeping legacy support for Ubuntu 16.04–21.04.

## Quick install (Ubuntu 24.04)

```bash
git clone https://github.com/Intteger157/h-mdm-remote-control.git
cd h-mdm-remote-control
```

Edit `config.yaml`:

```yaml
---
hostname: "remote.example.com"
email: "admin@example.com"
web_https_port: 443
nat: true
public_ip: "YOUR.PUBLIC.IP"
```

If MDM already uses port 443 on the same host, set a custom HTTPS port:

```yaml
web_https_port: 9443
```

Open firewall ports:

- `80/tcp` — Let's Encrypt HTTP challenge
- `web_https_port` (443 or 9443) — web-admin
- `8089/tcp`, `8989/tcp` — Janus REST / WSS
- `10000-10500/udp` — WebRTC screen cast

Run:

```bash
sudo ./install.sh
```

After success:

```bash
cat deploy/dist/credentials/janus_api_secret
docker compose ps
```

Web UI: `https://remote.example.com/web-admin/` (include `:9443` if configured).

## MDM integration (`deviceremote` plugin)

1. **Plugins → Remote control → Settings**
   - URL: `https://remote.example.com:9443/web-admin/` (match your port)
   - Secret: value from `janus_api_secret`
2. Deploy launcher + `com.hmdm.control` agent with the same URL/secret defaults.

## What changed vs upstream

| Area | Legacy | Modern (22.04+) |
|------|--------|-----------------|
| Ansible | 2.9 only | `ansible` from apt + collections |
| Python | pip docker-compose | apt `python3-docker`, `python3-dnspython` |
| Compose | docker-compose v1 binary | Docker Compose v2 plugin |
| Modules | `docker_compose` | `community.docker.docker_compose_v2` |

Legacy Ubuntu 20.04 and older still use the original Ansible 2.9 path.

## Troubleshooting

**Docker apt conflict (`docker.gpg` vs `docker.asc`)** — usually means Docker was already installed for MDM. The installer now detects this automatically. If apt is still broken, run once:

```bash
sudo rm -f /etc/apt/keyrings/docker.asc
sudo rm -f /etc/apt/sources.list.d/docker.list
# keep the existing docker.sources / docker.gpg if present
sudo apt update
git pull
sudo ./install.sh
```

**DNS check fails** — `hostname` in `config.yaml` must resolve to this server's public IP before install.

**Certbot fails on non-443 HTTPS** — Let's Encrypt HTTP-01 still uses port 80. Custom `web_https_port` only affects nginx HTTPS listener.

**Agent connects, no video** — open UDP `10000-10500` inbound and outbound.

**Re-run after config change**

```bash
sudo ansible-playbook deploy/pre_apuppet.yaml
sudo ansible-playbook deploy/start.yaml
```

Or full reinstall:

```bash
sudo ./install.sh
```

## Operation

```bash
cd ~/h-mdm-remote-control
docker compose ps
docker compose logs -f --tail=100
docker compose restart
docker compose down
```
