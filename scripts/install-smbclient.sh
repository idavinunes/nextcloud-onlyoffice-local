#!/usr/bin/env bash
set -euo pipefail

# Instala dependências para armazenamento externo SMB/CIFS no contêiner nc-app.
# OBS: deve ser reexecutado após atualizar/recriar a imagem do nc-app,
# a menos que você crie uma imagem customizada com esses pacotes.

CONTAINER="${CONTAINER:-nc-app}"

pkgs="smbclient libsmbclient-dev php8.2-smbclient"

echo "[info] instalando pacotes no contêiner ${CONTAINER}: ${pkgs}"
sudo docker exec "${CONTAINER}" bash -lc "apt-get update && apt-get install -y --no-install-recommends ${pkgs} && rm -rf /var/lib/apt/lists/*"

echo "[info] pronto. Ative o app 'Armazenamento externo' (files_external) no Nextcloud e configure o mount SMB."
