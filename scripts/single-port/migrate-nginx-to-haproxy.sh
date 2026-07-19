#!/usr/bin/env bash
# Migrate an existing nginx-stream single-port host to HAProxy SSL-terminate.
# Safe to re-run. Requires config.env (same as setup-single-port.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
load_config "$SCRIPT_DIR"

log "=== Migrate nginx stream -> HAProxy (scheme 2) ==="

ensure_haproxy_packages
patch_hmdm_compose
patch_mdm_proxy_context
free_port_80_for_host_edge

mkdir -p "$REMOTE_ACME_WEBROOT/.well-known/acme-challenge"
mkdir -p "$MDM_ACME_WEBROOT/.well-known/acme-challenge"

disable_host_nginx_edge
install_haproxy_config "$SCRIPT_DIR"

[[ -d "/etc/letsencrypt/live/${REMOTE_DOMAIN}" ]] || die "Missing LE cert for ${REMOTE_DOMAIN}"
[[ -d "/etc/letsencrypt/live/${MDM_DOMAIN}" ]] || die "Missing LE cert for ${MDM_DOMAIN} (RSA required for Tomcat)"

ensure_mdm_rsa_cert "$MDM_ACME_WEBROOT"
sync_haproxy_certs
reload_haproxy

sync_remote_certs_from_le
sync_mdm_certs_from_le

(cd "$HMDM_DOCKER_DIR" && docker compose up -d postgresql hmdm) || true
(cd "$REMOTE_DIR" && docker compose up -d nginx janus) || true

install_cron "$SCRIPT_DIR/renew-certificates.sh"

log ""
log "Migration done. Checks:"
log "  systemctl is-active haproxy nginx   # haproxy=active, nginx=inactive"
log "  ss -tlnp | grep -E ':443|:80'"
log "  curl -I https://${MDM_DOMAIN}/"
log "  curl -I https://${REMOTE_DOMAIN}/web-admin/"
log "After a device sync, Devices IP should no longer be 172.18.0.1"
