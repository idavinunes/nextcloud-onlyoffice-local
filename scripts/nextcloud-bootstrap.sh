#!/usr/bin/env bash
set -euo pipefail

cd /var/www/html

occ() {
  # run occ as www-data to avoid permission issues
  runuser -u www-data -- php occ "$@"
}

wait_for_occ() {
  local attempts=0 max_attempts=30
  local delay=5
  until occ status >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "${attempts}" -ge "${max_attempts}" ]; then
      echo "[bootstrap] occ ainda indisponível após ${max_attempts} tentativas; prosseguindo assim mesmo." >&2
      return
    fi
    echo "[bootstrap] aguardando Nextcloud (occ) ficar pronto... (${attempts}/${max_attempts})"
    sleep "${delay}"
  done
}

wait_for_occ

echo "[bootstrap] applying Nextcloud overwrite config..."

occ config:system:set overwrite.cli.url --value="${NC_OVERWRITE_CLI_URL}"
occ config:system:set overwritehost --value="${NC_OVERWRITE_HOST}"
occ config:system:set overwriteprotocol --value="${NC_OVERWRITE_PROTOCOL}"

# idioma padrão (aplicado no primeiro login de novos usuários)
if [ -n "${NC_DEFAULT_LANGUAGE:-}" ]; then
  occ config:system:set default_language --value="${NC_DEFAULT_LANGUAGE}"
fi
if [ -n "${NC_DEFAULT_LOCALE:-}" ]; then
  occ config:system:set default_locale --value="${NC_DEFAULT_LOCALE}"
fi

# trusted_domains (suporta lista separada por vírgula)
trusted_domains="${NC_TRUSTED_DOMAINS:-${NC_OVERWRITE_HOST:-}}"
if [ -n "${trusted_domains}" ]; then
  echo "[bootstrap] applying trusted_domains..."
  IFS=',' read -r -a domains <<<"${trusted_domains}"
  idx=0
  for domain in "${domains[@]}"; do
    clean_domain="$(echo "${domain}" | xargs)"
    if [ -n "${clean_domain}" ]; then
      occ config:system:set trusted_domains "${idx}" --value="${clean_domain}"
      idx=$((idx + 1))
    fi
  done
fi

# trusted_proxies (para proxy reverso/Nginx no host)
if [ -n "${NC_TRUSTED_PROXIES:-}" ]; then
  echo "[bootstrap] applying trusted_proxies..."
  IFS=',' read -r -a proxies <<<"${NC_TRUSTED_PROXIES}"
  idx=0
  for proxy in "${proxies[@]}"; do
    clean_proxy="$(echo "${proxy}" | xargs)"
    if [ -n "${clean_proxy}" ]; then
      occ config:system:set trusted_proxies "${idx}" --value="${clean_proxy}"
      idx=$((idx + 1))
    fi
  done
fi

echo "[bootstrap] applying cache/redis config..."
occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"
occ config:system:set redis host --value="${REDIS_HOST:-redis}"
occ config:system:set redis port --type=integer --value="${REDIS_PORT:-6379}"

# Ajuste de OPcache (tune default se variáveis existirem, senão usa defaults)
opcache_memory="${OPCACHE_MEMORY:-512}"
opcache_interned="${OPCACHE_INTERNED_STRINGS:-16}"
opcache_max_files="${OPCACHE_MAX_ACCELERATED_FILES:-100000}"
cat >/usr/local/etc/php/conf.d/opcache-tune.ini <<EOF
opcache.memory_consumption=${opcache_memory}
opcache.interned_strings_buffer=${opcache_interned}
opcache.max_accelerated_files=${opcache_max_files}
opcache.validate_timestamps=1
opcache.revalidate_freq=60
EOF
# Ajuste de memory_limit (default 768M; pode ser alterado via PHP_MEMORY_LIMIT)
php_memory_limit="${PHP_MEMORY_LIMIT:-768M}"
echo "memory_limit=${php_memory_limit}" >/usr/local/etc/php/conf.d/memory-limit.ini

echo "[bootstrap] ensuring OnlyOffice app installed/enabled..."
if ! occ app:enable onlyoffice >/dev/null 2>&1; then
  if occ app:install onlyoffice && occ app:enable onlyoffice; then
    echo "[bootstrap] OnlyOffice app instalado e habilitado."
  else
    echo "[bootstrap][warn] Não foi possível instalar/habilitar o app OnlyOffice (verifique conectividade e permissões)." >&2
  fi
fi

echo "[bootstrap] applying OnlyOffice app config..."

# ✅ Ajustes do app OnlyOffice (Nextcloud app)
occ config:app:set onlyoffice DocumentServerUrl --value="${OO_PUBLIC_URL}"
occ config:app:set onlyoffice DocumentServerInternalUrl --value="${OO_INTERNAL_URL}"
occ config:app:set onlyoffice StorageUrl --value="${NC_INTERNAL_URL}"
occ config:app:set onlyoffice jwt_secret --value="${OO_JWT_SECRET}"

echo "[bootstrap] done."
