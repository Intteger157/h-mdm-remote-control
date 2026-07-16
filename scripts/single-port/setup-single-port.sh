#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
load_config "$SCRIPT_DIR"

log "=== Headwind single-port 443 + certbot setup ==="
log "Remote: ${REMOTE_DOMAIN} -> 127.0.0.1:${REMOTE_HTTPS_PORT}"
log "MDM:    ${MDM_DOMAIN} -> 127.0.0.1:${MDM_HTTPS_PORT}"

ensure_nginx_stream_module
patch_hmdm_compose
free_port_80_for_host_nginx

mkdir -p /etc/nginx/stream.d /etc/nginx/sites-available /etc/nginx/sites-enabled
mkdir -p "$REMOTE_ACME_WEBROOT/.well-known/acme-challenge"
mkdir -p "$MDM_ACME_WEBROOT/.well-known/acme-challenge"

render_template "$SCRIPT_DIR/templates/sni-443.conf.template" /etc/nginx/stream.d/headwind-sni-443.conf
render_template "$SCRIPT_DIR/templates/acme-http.conf.template" /etc/nginx/sites-available/headwind-acme.conf
ln -sf /etc/nginx/sites-available/headwind-acme.conf /etc/nginx/sites-enabled/headwind-acme.conf

ensure_nginx_includes

nginx -t
systemctl enable nginx
systemctl restart nginx

log "Requesting / renewing TLS certificates via host certbot (port 80) ..."
issue_or_renew_cert "$REMOTE_DOMAIN" "$REMOTE_ACME_WEBROOT"
issue_or_renew_cert "$MDM_DOMAIN" "$MDM_ACME_WEBROOT"

sync_remote_certs_from_le
sync_mdm_certs_from_le

install_cron "$SCRIPT_DIR/renew-certificates.sh"

log ""
log "=== Done ==="
log "Public HTTPS (SNI on :443):"
log "  https://${REMOTE_DOMAIN}/web-admin/"
log "  https://${MDM_DOMAIN}/"
log ""
log "Janus ports must stay open in firewall: ${JANUS_HTTPS_PORT}/tcp ${JANUS_WSS_PORT}/tcp ${RTP_UDP_RANGE}/udp"
log "Renewal: weekly cron + manual: sudo ${SCRIPT_DIR}/renew-certificates.sh"
log ""
log "Restart MDM if not running:"
log "  cd ${HMDM_DOCKER_DIR} && docker compose up -d postgresql hmdm"
log ""
log "Verify:"
log "  ss -tlnp | grep ':443'"
log "  curl -kI https://${REMOTE_DOMAIN}/web-admin/"
log "  curl -kI https://${MDM_DOMAIN}/"
