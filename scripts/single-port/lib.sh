#!/usr/bin/env bash
set -euo pipefail

log() { echo "[single-port] $*"; }
die() { echo "[single-port] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."
}

load_config() {
  local script_dir="$1"
  local config_file="${2:-$script_dir/config.env}"
  [[ -f "$config_file" ]] || die "Missing $config_file — copy config.env.example to config.env"
  # shellcheck disable=SC1090
  source "$config_file"
  : "${REMOTE_DOMAIN:?}"
  : "${MDM_DOMAIN:?}"
  : "${CERTBOT_EMAIL:?}"
  : "${REMOTE_HTTPS_PORT:?}"
  : "${MDM_HTTPS_PORT:?}"
  : "${REMOTE_DIR:?}"
  : "${HMDM_DOCKER_DIR:?}"
  : "${HMDM_LETSENCRYPT_DIR:?}"
  : "${REMOTE_ACME_WEBROOT:?}"
  : "${MDM_ACME_WEBROOT:?}"
}

render_template() {
  local template="$1"
  local output="$2"
  sed \
    -e "s|__REMOTE_DOMAIN__|${REMOTE_DOMAIN}|g" \
    -e "s|__MDM_DOMAIN__|${MDM_DOMAIN}|g" \
    -e "s|__REMOTE_HTTPS_PORT__|${REMOTE_HTTPS_PORT}|g" \
    -e "s|__MDM_HTTPS_PORT__|${MDM_HTTPS_PORT}|g" \
    -e "s|__REMOTE_ACME_WEBROOT__|${REMOTE_ACME_WEBROOT}|g" \
    -e "s|__MDM_ACME_WEBROOT__|${MDM_ACME_WEBROOT}|g" \
    "$template" > "$output"
}

ensure_nginx_stream_module() {
  apt-get install -y nginx libnginx-mod-stream certbot
  ln -sf /usr/share/nginx/modules-available/mod-stream.conf \
    /etc/nginx/modules-enabled/50-mod-stream.conf
  [[ -f /etc/nginx/modules-enabled/50-mod-stream.conf ]] || die "nginx stream module missing"
}

ensure_nginx_includes() {
  local nginx_conf="/etc/nginx/nginx.conf"

  if ! grep -q 'include /etc/nginx/modules-enabled/\*\.conf;' "$nginx_conf"; then
    sed -i '1i include /etc/nginx/modules-enabled/*.conf;' "$nginx_conf"
  fi

  if ! grep -q 'include /etc/nginx/stream.d/\*\.conf;' "$nginx_conf"; then
    if grep -q '^stream {' "$nginx_conf"; then
      die "stream {} already exists in nginx.conf — merge include manually"
    fi
    awk '
      /^http \{/ && !done {
        print "stream {"
        print "    include /etc/nginx/stream.d/*.conf;"
        print "}"
        print ""
        done=1
      }
      { print }
    ' "$nginx_conf" > "${nginx_conf}.tmp"
    mv "${nginx_conf}.tmp" "$nginx_conf"
  fi

  if ! grep -q 'include /etc/nginx/sites-enabled/\*;' "$nginx_conf"; then
    log "nginx sites-enabled include already standard or custom layout"
  fi
}

free_port_80_for_host_nginx() {
  log "Stopping Remote docker nginx/certbot on host :80 ..."
  if [[ -d "$REMOTE_DIR" ]]; then
    (cd "$REMOTE_DIR" && docker compose stop certbot nginx 2>/dev/null) || true
    local remote_nginx_conf="$REMOTE_DIR/deploy/dist/conf/nginx/nginx.conf"
    if [[ -f "$remote_nginx_conf" ]]; then
      sed -i \
        -e "s/listen ${REMOTE_HTTPS_PORT} ssl http2;/listen ${REMOTE_HTTPS_PORT} ssl http2;/" \
        -e 's/listen 80;/listen 127.0.0.1:8080;/' \
        -e 's/listen \[::\]:80;/listen 127.0.0.1:8080;/' \
        "$remote_nginx_conf" || true
    fi
    (cd "$REMOTE_DIR" && docker compose up -d nginx janus 2>/dev/null) || true
  fi
}

patch_hmdm_compose() {
  local compose="$HMDM_DOCKER_DIR/docker-compose.yaml"
  [[ -f "$compose" ]] || die "MDM compose not found: $compose"

  cp -a "$compose" "${compose}.bak.single-port-$(date +%Y%m%d%H%M%S)"

  sed -i \
    -e 's#- "443:8443"#- "127.0.0.1:8443:8443"#g' \
    -e 's#- "443:8443/tcp"#- "127.0.0.1:8443:8443"#g' \
    -e 's#- "80:80"#- "127.0.0.1:8081:80"#g' \
    "$compose"

  log "Patched MDM compose (443 -> 127.0.0.1:8443, certbot 80 -> 127.0.0.1:8081)"
  log "Restart MDM: cd $HMDM_DOCKER_DIR && docker compose up -d postgresql hmdm"
}

sync_remote_certs_from_le() {
  mkdir -p "$REMOTE_DIR/deploy/dist/ssl"
  rsync -a --delete /etc/letsencrypt/ "$REMOTE_DIR/deploy/dist/ssl/"
  if [[ -d "$REMOTE_DIR" ]]; then
    (cd "$REMOTE_DIR" && docker compose exec -T nginx nginx -s reload 2>/dev/null) || \
      (cd "$REMOTE_DIR" && docker compose restart nginx 2>/dev/null) || true
  fi
}

sync_mdm_certs_from_le() {
  mkdir -p "$HMDM_LETSENCRYPT_DIR"
  rsync -a --delete /etc/letsencrypt/ "$HMDM_LETSENCRYPT_DIR/"
  if [[ -d "$HMDM_DOCKER_DIR" ]]; then
    (cd "$HMDM_DOCKER_DIR" && docker compose restart hmdm 2>/dev/null) || true
  fi
}

issue_or_renew_cert() {
  local domain="$1"
  local webroot="$2"
  mkdir -p "$webroot/.well-known/acme-challenge"
  if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
    log "Certificate directory exists for ${domain}"
    return 0
  fi
  log "Issuing certificate for ${domain} ..."
  certbot certonly --webroot -w "$webroot" \
    -d "$domain" \
    --email "$CERTBOT_EMAIL" \
    --agree-tos --non-interactive --no-eff-email
}

renew_all_certs() {
  log "Running certbot renew ..."
  certbot renew --quiet --no-random-sleep-on-renew
}

install_cron() {
  local renew_script="$1"
  local cron_line="0 4 * * 1 root ${renew_script} >> /var/log/headwind-cert-renew.log 2>&1"
  local cron_file="/etc/cron.d/headwind-cert-renew"
  echo "$cron_line" > "$cron_file"
  chmod 644 "$cron_file"
  log "Installed weekly cron: $cron_file"
}
