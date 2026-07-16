#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
load_config "$SCRIPT_DIR"

log "=== Certificate renewal ==="

free_port_80_for_host_nginx
ensure_acme_nginx "$SCRIPT_DIR"
systemctl reload nginx 2>/dev/null || systemctl restart nginx

ensure_host_certificates
renew_all_certs

sync_remote_certs_from_le
sync_mdm_certs_from_le

log_cert_status
log "Renewal complete."
