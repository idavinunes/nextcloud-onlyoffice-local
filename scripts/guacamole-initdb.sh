#!/usr/bin/env bash
set -euo pipefail

COMPOSE="docker compose -f guac-proxy/docker-compose.guacamole.yml"
DB_ROOT_PASS="${GUAC_DB_ROOT_PASSWORD:-guacroot}"

if ! ${COMPOSE} ps -q guac-db >/dev/null 2>&1; then
  echo "[error] Stack do Guacamole nao esta rodando. Suba com:"
  echo "  ${COMPOSE} up -d"
  exit 1
fi

if ${COMPOSE} exec -T guac-db mariadb -uroot -p"${DB_ROOT_PASS}" guacdb -e "SHOW TABLES LIKE 'guacamole_user';" 2>/dev/null | grep -q guacamole_user; then
  echo "[ok] Schema ja existe no banco. Nada a fazer."
  exit 0
fi

echo "[info] Importando schema do Guacamole no banco..."
${COMPOSE} exec -T guacamole /opt/guacamole/bin/initdb.sh --mysql \
  | ${COMPOSE} exec -T guac-db mariadb -uroot -p"${DB_ROOT_PASS}" guacdb

echo "[info] Reiniciando guacamole..."
${COMPOSE} restart guacamole
echo "[ok] Schema importado."
