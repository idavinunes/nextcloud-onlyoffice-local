#!/usr/bin/env bash
set -euo pipefail

# Instala dependências para armazenamento externo SMB/CIFS no contêiner nc-app.
# OBS: deve ser reexecutado após atualizar/recriar a imagem do nc-app,
# a menos que você crie uma imagem customizada com esses pacotes.

CONTAINER="${CONTAINER:-nc-app}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

pkgs_base="smbclient libsmbclient"
php_pkg="php-smbclient"

echo "[info] instalando pacotes no contêiner ${CONTAINER}: ${pkgs_base} + ${php_pkg} (tentativa 1)"
if ! ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "apt-get update && apt-get install -y --no-install-recommends ${pkgs_base} ${php_pkg} && rm -rf /var/lib/apt/lists/*"; then
  echo "[warn] ${php_pkg} não disponível; tentando pacotes versionados..."
  php_ver=$(${DOCKER_BIN} exec "${CONTAINER}" php -r 'echo PHP_MAJOR_VERSION;".";echo PHP_MINOR_VERSION;' 2>/dev/null || echo "")
  candidates=()
  [ -n "${php_ver}" ] && candidates+=("php${php_ver}-smbclient")
  candidates+=("php8.4-smbclient" "php8.3-smbclient" "php8.2-smbclient" "php8.1-smbclient" "php8.0-smbclient")
  installed=0
  for cand in "${candidates[@]}"; do
    echo "[info] tentando ${cand}"
    if ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "apt-get update && apt-get install -y --no-install-recommends ${pkgs_base} ${cand} && rm -rf /var/lib/apt/lists/*"; then
      installed=1
      break
    fi
  done
  if [ "${installed}" -ne 1 ]; then
    echo "[warn] Pacotes binários não disponíveis; tentando compilar via pecl..."
    build_pkgs_base="smbclient libsmbclient-dev gcc make autoconf pkg-config"
    php_dev_candidates=()
    [ -n "${php_ver}" ] && php_dev_candidates+=("php${php_ver}-dev" "php${php_ver}-pear")
    php_dev_candidates+=("php8.4-dev" "php8.4-pear" "php8.3-dev" "php8.3-pear" "php8.2-dev" "php8.2-pear" "php8.1-dev" "php8.1-pear" "php8.0-dev" "php8.0-pear" "php-dev" "php-pear")
    install_cmd="apt-get update && apt-get install -y --no-install-recommends ${build_pkgs_base}"
    found_pkg=""
    for dev in "${php_dev_candidates[@]}"; do
      if ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "apt-get update >/dev/null 2>&1 && apt-get install -y --no-install-recommends ${dev} >/dev/null 2>&1"; then
        install_cmd="${install_cmd} ${dev}"
        found_pkg="1"
        break
      fi
    done
    if [ -z "${found_pkg}" ]; then
      echo \"[error] Não foi possível instalar dependências de build para smbclient via pecl.\" >&2
      exit 1
    fi
    if ! ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "${install_cmd} && rm -rf /var/lib/apt/lists/* && pecl install smbclient && echo 'extension=smbclient.so' > /usr/local/etc/php/conf.d/docker-php-ext-smbclient.ini"; then
      echo \"[error] Falha ao compilar smbclient via pecl.\" >&2
      exit 1
    fi
    installed=1
  fi
fi

echo "[info] pronto. Ative o app 'Armazenamento externo' (files_external) no Nextcloud e configure o mount SMB."
