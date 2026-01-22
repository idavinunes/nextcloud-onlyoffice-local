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
  candidates+=("php8.2-smbclient" "php8.1-smbclient" "php8.0-smbclient")
  installed=0
  for cand in "${candidates[@]}"; do
    echo "[info] tentando ${cand}"
    if ${DOCKER_BIN} exec "${CONTAINER}" bash -lc "apt-get update && apt-get install -y --no-install-recommends ${pkgs_base} ${cand} && rm -rf /var/lib/apt/lists/*"; then
      installed=1
      break
    fi
  done
  if [ "${installed}" -ne 1 ]; then
    echo "[error] Não foi possível instalar php-smbclient. Verifique se o repositório padrão (Debian bookworm/trixie) está habilitado no contêiner e tente novamente."
    exit 1
  fi
fi

echo "[info] pronto. Ative o app 'Armazenamento externo' (files_external) no Nextcloud e configure o mount SMB."
