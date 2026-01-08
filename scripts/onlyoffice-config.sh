#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Arquivo .env não encontrado em ${ROOT_DIR}. Crie/ajuste antes de rodar este script." >&2
  exit 1
fi

# Carrega variáveis do .env
set -a
. "${ENV_FILE}"
set +a

required_vars=(OO_PUBLIC_URL OO_INTERNAL_URL NC_INTERNAL_URL OO_JWT_SECRET)
for v in "${required_vars[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "Variável obrigatória ausente: ${v}. Ajuste o .env." >&2
    exit 1
  fi
done

CMD="
cd /var/www/html && \
php occ config:app:set onlyoffice DocumentServerUrl --value=\"${OO_PUBLIC_URL}\" && \
php occ config:app:set onlyoffice DocumentServerInternalUrl --value=\"${OO_INTERNAL_URL}\" && \
php occ config:app:set onlyoffice StorageUrl --value=\"${NC_INTERNAL_URL}\" && \
php occ config:app:set onlyoffice jwt_secret --value=\"${OO_JWT_SECRET}\"
"

echo "[onlyoffice] aplicando config no nc-app..."
if ! docker exec -i -u www-data nc-app bash -lc "${CMD}"; then
  if [ -n "${SUDO:-}" ]; then
    echo "[warn] Sem permissão para docker, tentando com sudo..."
    ${SUDO} docker exec -i -u www-data nc-app bash -lc "${CMD}"
  else
    echo "[error] Falha ao executar docker exec; verifique permissões ou rode com sudo." >&2
    exit 1
  fi
fi
echo "[onlyoffice] pronto."
