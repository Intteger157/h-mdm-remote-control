#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
load_config "$SCRIPT_DIR"

log "=== Headwind single-port 443 via HAProxy (SSL terminate) ==="
log "Remote: ${REMOTE_DOMAIN} -> 127.0.0.1:${REMOTE_HTTPS_PORT}"
log "MDM:    ${MDM_DOMAIN} -> 127.0.0.1:${MDM_HTTPS_PORT}"

ensure_haproxy_packages
patch_hmdm_compose
patch_mdm_proxy_context
free_port_80_for_host_edge

mkdir -p "$REMOTE_ACME_WEBROOT/.well-known/acme-challenge"
mkdir -p "$MDM_ACME_WEBROOT/.well-known/acme-challenge"
mkdir -p /etc/haproxy/certs

# Stop nginx edge BEFORE binding HAProxy to :80/:443
disable_host_nginx_edge

install_haproxy_config "$SCRIPT_DIR"

# Issue certs while HAProxy already serves ACME on :80 (or use existing LE dirs)
log "Requesting / renewing TLS certificates via host certbot (port 80) ..."
# Temporary: if no certs yet, start HAProxy with snakeoil is awkward — prefer existing LE
# First boot with existing certs from previous nginx setup:
if [[ -d "/etc/letsencrypt/live/${REMOTE_DOMAIN}" && -d "/etc/letsencrypt/live/${MDM_DOMAIN}" ]]; then
  sync_haproxy_certs
  reload_haproxy
else
  # Start HAProxy only for ACME (HTTP frontend works without certs dir if HTTPS bind fails)
  # Create placeholder so haproxy -c passes: need at least one cert for bind crt dir
  if [[ ! -d /etc/haproxy/certs ]] || [[ -z "$(ls -A /etc/haproxy/certs 2>/dev/null || true)" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
      -keyout /tmp/haproxy-tmp.key -out /tmp/haproxy-tmp.crt \
      -subj "/CN=localhost" 2>/dev/null
    cat /tmp/haproxy-tmp.crt /tmp/haproxy-tmp.key > /etc/haproxy/certs/placeholder.pem
    chmod 600 /etc/haproxy/certs/placeholder.pem
    rm -f /tmp/haproxy-tmp.key /tmp/haproxy-tmp.crt
  fi
  reload_haproxy
fi

issue_or_renew_cert "$REMOTE_DOMAIN" "$REMOTE_ACME_WEBROOT"
ensure_mdm_rsa_cert "$MDM_ACME_WEBROOT"

sync_haproxy_certs
reload_haproxy

sync_remote_certs_from_le
sync_mdm_certs_from_le

# Ensure MDM is up with localhost publish
if [[ -d "$HMDM_DOCKER_DIR" ]]; then
  (cd "$HMDM_DOCKER_DIR" && docker compose up -d postgresql hmdm) || true
fi

install_cron "$SCRIPT_DIR/renew-certificates.sh"

log ""
log "=== Done ==="
log "Public HTTPS (HAProxy SSL terminate on :443):"
log "  https://${REMOTE_DOMAIN}/web-admin/"
log "  https://${MDM_DOMAIN}/"
log ""
log "Client IP: HAProxy sets X-Real-IP / X-Forwarded-For (MDM Devices column)."
log "Janus ports must stay open: ${JANUS_HTTPS_PORT}/tcp ${JANUS_WSS_PORT}/tcp ${RTP_UDP_RANGE}/udp"
log "Renewal: weekly cron + manual: sudo ${SCRIPT_DIR}/renew-certificates.sh"
log ""
log "Verify:"
log "  ss -tlnp | grep -E ':443|:80'"
log "  systemctl is-active haproxy"
log "  curl -I https://${REMOTE_DOMAIN}/web-admin/"
log "  curl -I https://${MDM_DOMAIN}/"
