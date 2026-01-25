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
CLIENT_PUSH_VER="${CLIENT_PUSH_VER:-}"
DEFAULT_PHONE_REGION="${NC_DEFAULT_PHONE_REGION:-${DEFAULT_PHONE_REGION:-BR}}"

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
  # Detecta versão do NC para escolher o tarball
  nc_ver="$(occ status 2>/dev/null | awk -F': ' '/versionstring/ {print $2}' | head -n1)"
  nc_major="${nc_ver%%.*}"
  fallback_ver="${CLIENT_PUSH_VER}"
  if [ -z "${fallback_ver}" ]; then
    case "${nc_major}" in
      32) fallback_ver="0.8.0" ;;
      31|30) fallback_ver="0.7.0" ;;
      29|28) fallback_ver="0.6.0" ;;
      27) fallback_ver="0.5.0" ;;
      *) fallback_ver="0.6.0" ;;
    esac
  fi
  echo "[warn] client_push via appstore falhou; tentando fallback v${fallback_ver} (Nextcloud ${nc_ver:-desconhecido})"
  if ! ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "
    set -e
    cd /tmp
    curl -fLO https://github.com/nextcloud-releases/client_push/releases/download/v${fallback_ver}/client_push-${fallback_ver}.tar.gz
    tar -xf client_push-${fallback_ver}.tar.gz -C /var/www/html/apps
    chown -R www-data:www-data /var/www/html/apps/client_push
  "; then
    echo "[warn] fallback client_push v${fallback_ver} não pôde ser baixado/aplicado (URL/versão ausente?). Ajuste CLIENT_PUSH_VER ou tente appstore novamente." >&2
  else
    occ app:enable client_push || true
  fi
fi

echo "[info] definindo maintenance_window_start=${MAINT_WINDOW_START}"
occ config:system:set maintenance_window_start --value="${MAINT_WINDOW_START}"

if [ -n "${DEFAULT_PHONE_REGION}" ]; then
  echo "[info] definindo default_phone_region=${DEFAULT_PHONE_REGION}"
  occ config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"
fi

echo "[info] rodando maintenance:repair --include-expensive (mimetypes, etc.)"
occ maintenance:repair --include-expensive
echo "[info] rodando db:add-missing-indices"
occ db:add-missing-indices || true

cat <<'EOF'
[info] Feito.
- AppAPI: se for usar Ex-Apps, configure o daemon em Configurações > Administração > Aplicativos Externos (app_api já foi instalado/habilitado).
- Talk: para chamadas com vários participantes, suba HPB + TURN e configure pelo occ talk:signaling/talk:turn.
- Cabeçalhos Forwarded: garanta trusted_proxies/overwrite* corretos e proxy com X-Forwarded-*.
- WebDAV CalDAV/CardDAV: já há rewrites no Nginx de host (/.well-known/caldav|carddav -> /remote.php/dav). Recarregue o Nginx após aplicar as confs.
- E-mail: configure SMTP em Configurações > Básicas ou via occ (mail_smtpmode/host/port/etc.) e use mail:test.
EOF
