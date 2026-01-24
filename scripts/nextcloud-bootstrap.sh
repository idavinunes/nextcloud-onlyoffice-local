#!/usr/bin/env bash
set -euo pipefail

cd /var/www/html

echo "[bootstrap] applying Nextcloud overwrite config..."

php occ config:system:set overwrite.cli.url --value="${NC_OVERWRITE_CLI_URL}"
php occ config:system:set overwritehost --value="${NC_OVERWRITE_HOST}"
php occ config:system:set overwriteprotocol --value="${NC_OVERWRITE_PROTOCOL}"

# idioma padrão (aplicado no primeiro login de novos usuários)
if [ -n "${NC_DEFAULT_LANGUAGE:-}" ]; then
  php occ config:system:set default_language --value="${NC_DEFAULT_LANGUAGE}"
fi
if [ -n "${NC_DEFAULT_LOCALE:-}" ]; then
  php occ config:system:set default_locale --value="${NC_DEFAULT_LOCALE}"
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
      php occ config:system:set trusted_domains "${idx}" --value="${clean_domain}"
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
      php occ config:system:set trusted_proxies "${idx}" --value="${clean_proxy}"
      idx=$((idx + 1))
    fi
  done
fi

echo "[bootstrap] applying cache/redis config..."
php occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
php occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"
php occ config:system:set redis host --value="${REDIS_HOST:-redis}"
php occ config:system:set redis port --type=integer --value="${REDIS_PORT:-6379}"

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

echo "[bootstrap] ensuring OnlyOffice app installed/enabled..."
php occ app:enable onlyoffice || { php occ app:install onlyoffice && php occ app:enable onlyoffice; }

echo "[bootstrap] applying OnlyOffice app config..."

# ✅ Ajustes do app OnlyOffice (Nextcloud app)
php occ config:app:set onlyoffice DocumentServerUrl --value="${OO_PUBLIC_URL}"
php occ config:app:set onlyoffice DocumentServerInternalUrl --value="${OO_INTERNAL_URL}"
php occ config:app:set onlyoffice StorageUrl --value="${NC_INTERNAL_URL}"
php occ config:app:set onlyoffice jwt_secret --value="${OO_JWT_SECRET}"

echo "[bootstrap] done."
