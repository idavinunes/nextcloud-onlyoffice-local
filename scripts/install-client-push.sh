#!/usr/bin/env bash
set -euo pipefail

# Instala/habilita client_push com fallback manual (tarball) para versões sem appstore.
# Ajuste VER conforme a versão do Nextcloud suportada:
# - NC 32: client_push 0.8.0 (até 0.8.x)
# - NC 31/30: 0.7.x / 0.6.x, se necessário

VER="${VER:-0.8.0}"
CONTAINER="${CONTAINER:-nc-app}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

occ() {
  ${DOCKER_BIN} exec -u www-data "${CONTAINER}" php occ "$@"
}

echo "[info] tentando instalar client_push via appstore..."
if occ app:install client_push && occ app:enable client_push; then
  echo "[ok] client_push instalado/ativado via appstore."
  exit 0
fi

echo "[warn] appstore falhou; tentando fallback manual com client_push v${VER}."
${DOCKER_BIN} exec "${CONTAINER}" bash -lc "
  set -e
  cd /tmp
  curl -LO https://github.com/nextcloud-releases/client_push/releases/download/v${VER}/client_push-${VER}.tar.gz
  tar -xf client_push-${VER}.tar.gz -C /var/www/html/apps
  chown -R www-data:www-data /var/www/html/apps/client_push
"

occ app:enable client_push
echo "[ok] client_push instalado/ativado (tarball v${VER})."
