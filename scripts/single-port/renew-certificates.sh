#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
load_config "$SCRIPT_DIR"

log "=== Certificate renewal (HAProxy edge) ==="

free_port_80_for_host_edge
mkdir -p "$REMOTE_ACME_WEBROOT/.well-known/acme-challenge"
mkdir -p "$MDM_ACME_WEBROOT/.well-known/acme-challenge"

install_haproxy_config "$SCRIPT_DIR"
sync_haproxy_certs
reload_haproxy

ensure_host_certificates
renew_all_certs

sync_haproxy_certs
reload_haproxy

sync_remote_certs_from_le
sync_mdm_certs_from_le

log_cert_status
log "Renewal complete."
