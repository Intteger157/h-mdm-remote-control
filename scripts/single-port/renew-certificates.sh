#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
load_config "$SCRIPT_DIR"

log "=== Certificate renewal ==="

free_port_80_for_host_nginx
systemctl reload nginx 2>/dev/null || systemctl restart nginx

renew_all_certs

sync_remote_certs_from_le
sync_mdm_certs_from_le

log "Renewal complete."
