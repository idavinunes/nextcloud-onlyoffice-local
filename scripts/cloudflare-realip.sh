#!/usr/bin/env bash
set -euo pipefail

# Gera um include Nginx com IPs da Cloudflare para restaurar o IP real do cliente.
# Uso: sudo bash scripts/cloudflare-realip.sh

SUDO="${SUDO:-sudo}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
TARGET="${NGINX_CONF_DIR}/cloudflare-realip.conf"

TMP="$(mktemp)"
cleanup() { rm -f "${TMP}"; }
trap cleanup EXIT

echo "[info] baixando lista de IPs da Cloudflare..."
curl -fsSL https://www.cloudflare.com/ips-v4 >"${TMP}"
curl -fsSL https://www.cloudflare.com/ips-v6 >>"${TMP}"

${SUDO} mkdir -p "${NGINX_CONF_DIR}"
{
  echo "# Gerado por scripts/cloudflare-realip.sh - $(date -Iseconds)"
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
  while IFS= read -r cidr; do
    [ -n "${cidr}" ] && echo "set_real_ip_from ${cidr};"
  done <"${TMP}"
} | ${SUDO} tee "${TARGET}" >/dev/null

echo "[info] escrito em ${TARGET}"
echo "[info] recarregue o Nginx: sudo nginx -t && sudo systemctl reload nginx"
