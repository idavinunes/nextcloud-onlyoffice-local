#!/usr/bin/env bash
set -euo pipefail

# Roteiro rápido para avisos comuns pós-instalação.
# Faz:
# - instala/habilita client_push e notifications;
# - tenta instalar app_api (para silenciar aviso do AppAPI, se necessário);
# - define maintenance_window_start (padrão 1 = 01:00);
# - roda maintenance:repair --include-expensive;
# - lembra de AppAPI e Talk HPB/TURN se necessário.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[erro] .env não encontrado em ${ROOT_DIR}" >&2
  exit 1
fi

set -a
. "${ENV_FILE}"
set +a

DOCKER_BIN="${DOCKER_BIN:-docker}"
CONTAINER="${CONTAINER:-nc-app}"
MAINT_WINDOW_START="${MAINT_WINDOW_START:-1}" # 1 = 01:00
CLIENT_PUSH_VER="${CLIENT_PUSH_VER:-0.8.0}"

occ() {
  ${DOCKER_BIN} exec -u www-data "${CONTAINER}" php occ "$@"
}

install_app() {
  local app="$1"
  echo "[info] instalando/habilitando ${app}"
  occ app:install "${app}" || true
  occ app:enable "${app}" || true
}

echo "[info] usando contêiner ${CONTAINER} via ${DOCKER_BIN}"

install_app "client_push"
install_app "notifications"
install_app "app_api"
if ! occ app:list | grep -q '^Enabled:.*client_push'; then
  echo "[warn] client_push via appstore falhou; tentando fallback v${CLIENT_PUSH_VER}"
  ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "
    set -e
    cd /tmp
    curl -LO https://github.com/nextcloud-releases/client_push/releases/download/v${CLIENT_PUSH_VER}/client_push-${CLIENT_PUSH_VER}.tar.gz
    tar -xf client_push-${CLIENT_PUSH_VER}.tar.gz -C /var/www/html/apps
    chown -R www-data:www-data /var/www/html/apps/client_push
  "
  occ app:enable client_push || true
fi

echo "[info] definindo maintenance_window_start=${MAINT_WINDOW_START}"
occ config:system:set maintenance_window_start --value="${MAINT_WINDOW_START}"

echo "[info] rodando maintenance:repair --include-expensive (mimetypes, etc.)"
occ maintenance:repair --include-expensive

cat <<'EOF'
[info] Feito.
- AppAPI: se for usar Ex-Apps, configure o daemon em Configurações > Administração > Aplicativos Externos (app_api já foi instalado/habilitado).
- Talk: para chamadas com vários participantes, suba HPB + TURN e configure pelo occ talk:signaling/talk:turn.
- Cabeçalhos Forwarded: garanta trusted_proxies/overwrite* corretos e proxy com X-Forwarded-*.
EOF
