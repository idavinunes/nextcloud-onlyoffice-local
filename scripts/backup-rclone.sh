#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Arquivo .env não encontrado em ${ROOT_DIR}. Crie/ajuste antes de rodar este script." >&2
  exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker não encontrado no PATH." >&2
  exit 1
fi

# Carrega variáveis do .env
set -a
. "${ENV_FILE}"
set +a

required_vars=(NC_DB_VOLUME NC_APP_VOLUME NC_DATA_VOLUME OO_PG_VOLUME OO_DATA_VOLUME OO_LOGS_VOLUME OO_LIB_VOLUME)
for v in "${required_vars[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "Variável obrigatória ausente: ${v}. Ajuste o .env." >&2
    exit 1
  fi
done

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_BASE="${BACKUP_BASE:-/tmp}"
BACKUP_DIR="${BACKUP_BASE%/}/nc-oo-backup-${STAMP}"
mkdir -p "${BACKUP_DIR}/db" "${BACKUP_DIR}/files"

echo "[backup] dump do MariaDB (Nextcloud)..."
docker exec nc-db sh -c 'mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' > "${BACKUP_DIR}/db/nextcloud.sql"

echo "[backup] dump do PostgreSQL (OnlyOffice)..."
docker exec oo-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > "${BACKUP_DIR}/db/onlyoffice.sql"

archive_dir() {
  local path="$1" name="$2"
  if [ ! -d "${path}" ]; then
    echo "[warn] diretório não encontrado, pulando: ${path}"
    return
  fi
  echo "[backup] arquivando ${path} -> ${name}.tar.gz"
  ${SUDO} tar czf "${BACKUP_DIR}/files/${name}.tar.gz" -C "$(dirname "${path}")" "$(basename "${path}")"
}

archive_dir "${NC_APP_VOLUME}" "nc-app"
archive_dir "${NC_DATA_VOLUME}" "nc-data"
archive_dir "${OO_PG_VOLUME}" "oo-postgres-data"
archive_dir "${OO_DATA_VOLUME}" "oo-data"
archive_dir "${OO_LOGS_VOLUME}" "oo-logs"
archive_dir "${OO_LIB_VOLUME}" "oo-lib"

cp "${ENV_FILE}" "${BACKUP_DIR}/env.snapshot"

REMOTE_TARGET="${1:-${RCLONE_TARGET:-}}"
if [ -n "${REMOTE_TARGET}" ]; then
  if ! command -v rclone >/dev/null 2>&1; then
    echo "[warn] rclone não encontrado; backup local em ${BACKUP_DIR}" >&2
  else
    DEST="${REMOTE_TARGET%/}/nc-oo-${STAMP}"
    echo "[backup] enviando para rclone: ${DEST}"
    rclone copy "${BACKUP_DIR}" "${DEST}"
  fi
else
  echo "[info] rclone não configurado (passe remote:path como argumento ou defina RCLONE_TARGET). Backup local em ${BACKUP_DIR}"
fi

echo "[ok] backup concluído em ${BACKUP_DIR}"
