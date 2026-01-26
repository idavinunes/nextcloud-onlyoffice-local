#!/usr/bin/env bash
set -euo pipefail

# Instala/ativa apps recomendados pós-instalação.
# Personalize a lista conforme sua necessidade.

CONTAINER="${CONTAINER:-nc-app}"
APPS=(
  "logreader"
  "admin_audit"
  "files_external"
  "external"
  "groupfolders"
  "analytics"
  "bruteforcesettings"
  "calendar"
  "contacts"
  "mail"
  "impersonate"
  "monitoring"
  "notifications"
  "password_policy"
  "passwords"
  "photos"
  "privacy"
  "recommendations"
  "text"
  "twofactor_totp"
  "user_status"
  "versions"
  "weather_status"
)

echo "[info] Instalando/ativando apps: ${APPS[*]}"
for app in "${APPS[@]}"; do
  echo "[info] ${app}"
  sudo docker exec -u www-data "${CONTAINER}" php occ app:install "${app}" || true
  sudo docker exec -u www-data "${CONTAINER}" php occ app:enable "${app}" || true
done

echo "[info] Concluído."
