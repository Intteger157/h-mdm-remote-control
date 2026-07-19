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

# ---------------------------------------------------------------------------
# Host edge: HAProxy (SSL terminate) replaces nginx stream SNI
# ---------------------------------------------------------------------------

ensure_haproxy_packages() {
  apt-get install -y haproxy certbot rsync openssl
  systemctl enable haproxy
}

disable_host_nginx_edge() {
  log "Disabling host nginx edge (:80/:443) — HAProxy takes over ..."
  systemctl stop nginx 2>/dev/null || true
  systemctl disable nginx 2>/dev/null || true

  # Remove single-port nginx artifacts so a later nginx start cannot steal :443
  rm -f /etc/nginx/stream.d/headwind-sni-443.conf \
        /etc/nginx/stream.d/sni-443.conf \
        /etc/nginx/sites-enabled/headwind-acme.conf 2>/dev/null || true
}

install_haproxy_config() {
  local script_dir="$1"
  mkdir -p /etc/haproxy /etc/haproxy/certs
  render_template "$script_dir/templates/haproxy.cfg.template" /etc/haproxy/haproxy.cfg
  # Keep a stamped copy for debugging
  cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.headwind"
  log "Wrote /etc/haproxy/haproxy.cfg"
}

# Build PEM bundles (fullchain+privkey) that HAProxy SNI can load from a directory.
sync_haproxy_certs() {
  mkdir -p /etc/haproxy/certs
  local domain pem
  for domain in "$REMOTE_DOMAIN" "$MDM_DOMAIN"; do
    if [[ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      log "WARNING: missing LE cert for ${domain} — skip HAProxy bundle"
      continue
    fi
    pem="/etc/haproxy/certs/${domain}.pem"
    cat "/etc/letsencrypt/live/${domain}/fullchain.pem" \
        "/etc/letsencrypt/live/${domain}/privkey.pem" > "$pem"
    chmod 600 "$pem"
    log "HAProxy cert bundle: $pem"
  done
}

reload_haproxy() {
  if ! haproxy -c -f /etc/haproxy/haproxy.cfg; then
    die "haproxy.cfg failed validation"
  fi
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
  log "HAProxy reloaded"
}

# ---------------------------------------------------------------------------
# Backends stay on localhost HTTPS; free public :80 from Remote docker
# ---------------------------------------------------------------------------

free_port_80_for_host_edge() {
  log "Stopping Remote docker nginx/certbot on host :80 ..."
  if [[ -d "$REMOTE_DIR" ]]; then
    (cd "$REMOTE_DIR" && docker compose stop certbot nginx 2>/dev/null) || true
    local remote_nginx_conf="$REMOTE_DIR/deploy/dist/conf/nginx/nginx.conf"
    if [[ -f "$remote_nginx_conf" ]]; then
      sed -i \
        -e 's/listen 80;/listen 127.0.0.1:8080;/' \
        -e 's/listen \[::\]:80;/listen 127.0.0.1:8080;/' \
        "$remote_nginx_conf" || true
      # Real client IP from HAProxy (scheme 2)
      if ! grep -q 'real_ip_header X-Real-IP' "$remote_nginx_conf"; then
        sed -i '/http {/a\    set_real_ip_from 127.0.0.1;\n    real_ip_header X-Real-IP;\n    real_ip_recursive on;' \
          "$remote_nginx_conf" || true
      fi
    fi
    local remote_cfg="$REMOTE_DIR/config.yaml"
    if [[ -f "$remote_cfg" ]]; then
      if grep -qE '^[[:space:]]*web_http_listen:' "$remote_cfg"; then
        sed -i 's|^[[:space:]]*web_http_listen:.*|web_http_listen: "127.0.0.1:8080"|' "$remote_cfg"
      else
        printf '\nweb_http_listen: "127.0.0.1:8080"\n' >> "$remote_cfg"
      fi
    fi
    (cd "$REMOTE_DIR" && docker compose up -d nginx janus 2>/dev/null) || true
  fi
}

# Back-compat alias used by older renew scripts / docs
free_port_80_for_host_nginx() { free_port_80_for_host_edge; }

patch_hmdm_compose() {
  local compose="$HMDM_DOCKER_DIR/docker-compose.yaml"
  [[ -f "$compose" ]] || die "MDM compose not found: $compose"

  cp -a "$compose" "${compose}.bak.single-port-$(date +%Y%m%d%H%M%S)"

  sed -i \
    -e 's#- "443:8443"#- "127.0.0.1:8443:8443"#g' \
    -e 's#- "443:8443/tcp"#- "127.0.0.1:8443:8443"#g' \
    -e 's#- "0.0.0.0:8443:8443"#- "127.0.0.1:8443:8443"#g' \
    -e 's#- "8443:8443"#- "127.0.0.1:8443:8443"#g' \
    -e 's#- "80:80"#- "127.0.0.1:8081:80"#g' \
    "$compose"

  log "Patched MDM compose (public ports -> 127.0.0.1:8443 / :8081)"
  log "Restart MDM: cd $HMDM_DOCKER_DIR && docker compose up -d postgresql hmdm"
}

# Tell Headwind Tomcat to trust HAProxy and read X-Real-IP
patch_mdm_proxy_context() {
  local ctx=""
  local candidate

  for candidate in \
    "$HMDM_DOCKER_DIR/volumes/tomcat/conf/context.xml" \
    "$HMDM_DOCKER_DIR/tomcat/conf/context.xml" \
    "$HMDM_DOCKER_DIR/conf/context.xml" \
    "$HMDM_DOCKER_DIR/context.xml"; do
    if [[ -f "$candidate" ]]; then
      ctx="$candidate"
      break
    fi
  done

  if [[ -z "$ctx" ]]; then
    ctx="$(find "$HMDM_DOCKER_DIR" -name 'context.xml' 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$ctx" || ! -f "$ctx" ]]; then
    log "WARNING: MDM context.xml not found on host — set inside the container and restart hmdm:"
    log "  <Parameter name=\"proxy.addresses\" value=\"127.0.0.1\"/>"
    log "  <Parameter name=\"proxy.ip.header\" value=\"X-Real-IP\"/>"
    return 0
  fi

  cp -a "$ctx" "${ctx}.bak.haproxy-$(date +%Y%m%d%H%M%S)"

  # Drop old proxy.* lines (commented or not) then insert clean ones before </Context>
  sed -i '/proxy\.addresses/d;/proxy\.ip\.header/d' "$ctx"
  if grep -q '</Context>' "$ctx"; then
    sed -i 's|</Context>|    <Parameter name="proxy.addresses" value="127.0.0.1"/>\n    <Parameter name="proxy.ip.header" value="X-Real-IP"/>\n</Context>|' "$ctx"
    log "Patched MDM proxy headers in $ctx"
  else
    log "WARNING: no </Context> in $ctx — add proxy.addresses manually"
  fi
}

sync_remote_certs_from_le() {
  if [[ ! -d "/etc/letsencrypt/live/${REMOTE_DOMAIN}" ]]; then
    log "WARNING: No host cert for ${REMOTE_DOMAIN} — Remote Docker volume left unchanged"
    return 0
  fi
  mkdir -p "$REMOTE_DIR/deploy/dist/ssl"
  rsync -a /etc/letsencrypt/ "$REMOTE_DIR/deploy/dist/ssl/"
  if [[ -d "$REMOTE_DIR" ]]; then
    (cd "$REMOTE_DIR" && docker compose exec -T nginx nginx -s reload 2>/dev/null) || \
      (cd "$REMOTE_DIR" && docker compose restart nginx 2>/dev/null) || true
  fi
  log "Synced host certs -> ${REMOTE_DIR}/deploy/dist/ssl/"
}

sync_mdm_certs_from_le() {
  if [[ ! -d "/etc/letsencrypt/live/${MDM_DOMAIN}" ]]; then
    log "WARNING: No host cert for ${MDM_DOMAIN} — MDM Docker volume left unchanged"
    return 0
  fi
  mkdir -p "$HMDM_LETSENCRYPT_DIR"
  rsync -aL /etc/letsencrypt/ "$HMDM_LETSENCRYPT_DIR/"
  if [[ -d "$HMDM_DOCKER_DIR" ]]; then
    reload_mdm_tomcat_ssl
    verify_mdm_https_backend || true
  fi
  log "Synced host certs -> ${HMDM_LETSENCRYPT_DIR}/"
}

cert_public_key_type() {
  local domain="$1"
  local key="/etc/letsencrypt/live/${domain}/privkey.pem"
  local certbot_type

  certbot_type="$(certbot certificates 2>/dev/null | awk -v d="$domain" '
    $0 ~ "Certificate Name: " d { show=1; next }
    show && /Key Type:/ { print tolower($3); exit }
  ')"

  case "$certbot_type" in
    ecdsa|ec) echo "ec"; return 0 ;;
    rsa) echo "rsa"; return 0 ;;
  esac

  [[ -f "$key" ]] || return 1
  if openssl ec -in "$key" -noout 2>/dev/null; then
    echo "ec"
  elif openssl rsa -in "$key" -noout 2>/dev/null; then
    echo "rsa"
  else
    echo "unknown"
  fi
}

reissue_mdm_rsa_cert() {
  local webroot="$1"
  log "Re-issuing ${MDM_DOMAIN} as RSA (Tomcat hmdm.jks requires RSA) ..."
  certbot certonly --webroot -w "$webroot" \
    -d "$MDM_DOMAIN" \
    --cert-name "$MDM_DOMAIN" \
    --key-type rsa --force-renewal \
    --email "$CERTBOT_EMAIL" \
    --agree-tos --non-interactive --no-eff-email
}

reload_mdm_tomcat_ssl() {
  local container
  container="$(cd "$HMDM_DOCKER_DIR" && docker compose ps -q hmdm 2>/dev/null | head -n1)"
  [[ -n "$container" ]] || {
    log "WARNING: MDM container not found — restart manually: cd $HMDM_DOCKER_DIR && docker compose restart hmdm"
    return 0
  }

  log "Restarting MDM Tomcat to rebuild hmdm.jks ..."
  (cd "$HMDM_DOCKER_DIR" && docker compose restart hmdm) || die "Failed to restart MDM container"

  local i
  for i in $(seq 1 30); do
    if docker exec "$container" test -f /usr/local/tomcat/ssl/hmdm.jks 2>/dev/null; then
      log "MDM SSL keystore ready"
      return 0
    fi
    sleep 2
  done
  log "WARNING: hmdm.jks not found after restart — check: docker compose -f $HMDM_DOCKER_DIR/docker-compose.yaml logs hmdm"
}

verify_mdm_https_backend() {
  log "Waiting for MDM Tomcat on 127.0.0.1:${MDM_HTTPS_PORT} ..."
  local i
  for i in $(seq 1 60); do
    if curl -kfsS --max-time 3 \
      "https://127.0.0.1:${MDM_HTTPS_PORT}/" \
      --resolve "${MDM_DOMAIN}:${MDM_HTTPS_PORT}:127.0.0.1" \
      -o /dev/null 2>/dev/null; then
      log "MDM HTTPS backend OK on 127.0.0.1:${MDM_HTTPS_PORT}"
      return 0
    fi
    sleep 3
  done
  log "WARNING: MDM not responding on HTTPS :${MDM_HTTPS_PORT} — run:"
  log "  cd ${HMDM_DOCKER_DIR} && docker compose logs hmdm --tail=80"
  return 1
}

issue_or_renew_cert() {
  local domain="$1"
  local webroot="$2"
  local key_type="${3:-}"
  local -a certbot_args=()

  mkdir -p "$webroot/.well-known/acme-challenge"
  [[ -n "$key_type" ]] && certbot_args+=(--key-type "$key_type")

  if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
    log "Certificate directory exists for ${domain}"
    return 0
  fi

  log "Issuing certificate for ${domain}${key_type:+ (${key_type})} ..."
  certbot certonly --webroot -w "$webroot" \
    -d "$domain" \
    "${certbot_args[@]}" \
    --email "$CERTBOT_EMAIL" \
    --agree-tos --non-interactive --no-eff-email
}

ensure_mdm_rsa_cert() {
  local webroot="$1"

  if [[ ! -d "/etc/letsencrypt/live/${MDM_DOMAIN}" ]]; then
    issue_or_renew_cert "$MDM_DOMAIN" "$webroot" rsa
    return 0
  fi

  local key_type
  key_type="$(cert_public_key_type "$MDM_DOMAIN")"
  if [[ "$key_type" == "ec" ]]; then
    reissue_mdm_rsa_cert "$webroot"
  elif [[ "$key_type" == "rsa" ]]; then
    log "MDM certificate is RSA (OK for Tomcat)"
  else
    log "WARNING: MDM key type unclear (${key_type}) — attempting RSA re-issue ..."
    reissue_mdm_rsa_cert "$webroot" || true
  fi
}

# Legacy name kept for renew-certificates.sh callers
ensure_acme_nginx() {
  local script_dir="$1"
  mkdir -p "$REMOTE_ACME_WEBROOT/.well-known/acme-challenge"
  mkdir -p "$MDM_ACME_WEBROOT/.well-known/acme-challenge"
  install_haproxy_config "$script_dir"
  sync_haproxy_certs
  reload_haproxy
}

ensure_host_certificates() {
  issue_or_renew_cert "$REMOTE_DOMAIN" "$REMOTE_ACME_WEBROOT"
  ensure_mdm_rsa_cert "$MDM_ACME_WEBROOT"
}

renew_all_certs() {
  log "Running certbot renew ..."
  certbot renew --quiet --no-random-sleep-on-renew
}

log_cert_status() {
  log "Host certificates:"
  certbot certificates 2>/dev/null | sed 's/^/[single-port]   /' || true
  for domain in "$REMOTE_DOMAIN" "$MDM_DOMAIN"; do
    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
      log "  OK  ${domain}"
    else
      log "  MISSING  ${domain} — run setup-single-port.sh or fix port-80 ACME"
    fi
  done
}

install_cron() {
  local renew_script="$1"
  local cron_line="0 4 * * 1 root ${renew_script} >> /var/log/headwind-cert-renew.log 2>&1"
  local cron_file="/etc/cron.d/headwind-cert-renew"
  echo "$cron_line" > "$cron_file"
  chmod 644 "$cron_file"
  log "Installed weekly cron: $cron_file"
}
