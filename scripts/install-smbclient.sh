#!/usr/bin/env bash
set -euo pipefail

# Instala dependências para armazenamento externo SMB/CIFS no contêiner nc-app.
# OBS: deve ser reexecutado após atualizar/recriar a imagem do nc-app,
# a menos que você crie uma imagem customizada com esses pacotes.

CONTAINER="${CONTAINER:-nc-app}"

pkgs_base="smbclient libsmbclient"
php_pkg="php-smbclient"

echo "[info] instalando pacotes no contêiner ${CONTAINER}: ${pkgs_base} + ${php_pkg} (tentativa 1)"
if ! sudo docker exec "${CONTAINER}" bash -lc "apt-get update && apt-get install -y --no-install-recommends ${pkgs_base} ${php_pkg} && rm -rf /var/lib/apt/lists/*"; then
  echo "[warn] ${php_pkg} não disponível; tentando pacote versionado..."
  php_ver=$(sudo docker exec "${CONTAINER}" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
  php_pkg="php${php_ver}-smbclient"
  echo "[info] tentando ${php_pkg}"
  sudo docker exec "${CONTAINER}" bash -lc "apt-get update && apt-get install -y --no-install-recommends ${pkgs_base} ${php_pkg} && rm -rf /var/lib/apt/lists/*"
fi

echo "[info] pronto. Ative o app 'Armazenamento externo' (files_external) no Nextcloud e configure o mount SMB."
