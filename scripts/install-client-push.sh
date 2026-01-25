#!/usr/bin/env bash
set -euo pipefail

# Instala/habilita client_push com fallback manual (tarball) para versões sem appstore.
# Detecta a versão do Nextcloud para escolher o tarball; pode sobrescrever com VER=... ou CLIENT_PUSH_VER=...

CONTAINER="${CONTAINER:-nc-app}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

occ() {
  ${DOCKER_BIN} exec -u www-data "${CONTAINER}" php occ "$@"
}

get_nc_version() {
  occ status 2>/dev/null | awk -F': ' '/versionstring/ {print $2}' | head -n1
}

pick_client_push_ver() {
  local nc_ver="$1" nc_major default="${CLIENT_PUSH_VER:-0.8.0}"
  nc_major="${nc_ver%%.*}"
  case "${nc_major}" in
    32) echo "0.8.0" ;;
    31) echo "0.7.0" ;;
    30) echo "0.7.0" ;;
    29) echo "0.6.0" ;;
    *) echo "${default}" ;;
  esac
}

NC_VERSION="$(get_nc_version || true)"
TARGET_VER="${VER:-$(pick_client_push_ver "${NC_VERSION:-}")}"

echo "[info] Nextcloud=${NC_VERSION:-desconhecido} | client_push alvo=${TARGET_VER}"
echo "[info] tentando instalar client_push via appstore..."
if occ app:install client_push && occ app:enable client_push; then
  echo "[ok] client_push instalado/ativado via appstore."
  exit 0
fi

echo "[warn] appstore falhou; tentando fallback manual com client_push v${TARGET_VER}."
if ! ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "
  set -e
  cd /tmp
  curl -fLO https://github.com/nextcloud-releases/client_push/releases/download/v${TARGET_VER}/client_push-${TARGET_VER}.tar.gz
  tar -xf client_push-${TARGET_VER}.tar.gz -C /var/www/html/apps
  chown -R www-data:www-data /var/www/html/apps/client_push
"; then
  echo "[error] download/extração do client_push v${TARGET_VER} falhou (URL/versão não encontrada?). Ajuste VER/CLIENT_PUSH_VER ou verifique appstore." >&2
  exit 1
fi

occ app:enable client_push
echo "[ok] client_push instalado/ativado (tarball v${TARGET_VER})."
