#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Instale sudo ou execute como root." >&2
    exit 1
  fi
fi

ensure_pkg() {
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y "$@"
}

prompt_default() {
  local prompt="$1" default="$2" reply
  if [ -t 0 ]; then
    read -r -p "${prompt} [${default}]: " reply || true
    echo "${reply:-${default}}"
  else
    echo "${default}"
  fi
}

if ! command -v rclone >/dev/null 2>&1; then
  echo "[info] Instalando rclone..."
  ensure_pkg rclone
else
  echo "[ok] rclone ja instalado."
fi

if ! command -v fusermount3 >/dev/null 2>&1; then
  echo "[info] Instalando fuse3..."
  ensure_pkg fuse3
fi

if [ ! -f /etc/fuse.conf ]; then
  echo "[info] Criando /etc/fuse.conf com user_allow_other..."
  echo "user_allow_other" | ${SUDO} tee /etc/fuse.conf >/dev/null
elif ! grep -qE '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
  echo "[info] Habilitando user_allow_other em /etc/fuse.conf..."
  ${SUDO} sed -i 's/^[[:space:]]*#\s*user_allow_other/user_allow_other/' /etc/fuse.conf || true
  if ! grep -qE '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
    echo "user_allow_other" | ${SUDO} tee -a /etc/fuse.conf >/dev/null
  fi
fi

RCLONE_BASE_DEFAULT="${RCLONE_BASE:-/data}"
RCLONE_BASE="$(prompt_default "Base para mounts rclone" "${RCLONE_BASE_DEFAULT}")"

RCLONE_CACHE_DEFAULT="${RCLONE_CACHE_DIR:-${RCLONE_BASE%/}/rclone-cache}"
RCLONE_CACHE_DIR="$(prompt_default "Cache do rclone" "${RCLONE_CACHE_DEFAULT}")"

GDRIVE_MOUNT_DEFAULT="${GDRIVE_MOUNT:-${RCLONE_BASE%/}/gdrive}"
GDRIVE_MOUNT="$(prompt_default "Pasta de mount do GDrive" "${GDRIVE_MOUNT_DEFAULT}")"

DROPBOX_MOUNT_DEFAULT="${DROPBOX_MOUNT:-${RCLONE_BASE%/}/dropbox}"
DROPBOX_MOUNT="$(prompt_default "Pasta de mount do Dropbox" "${DROPBOX_MOUNT_DEFAULT}")"

GDRIVE_SOURCE_DEFAULT="${GDRIVE_SOURCE:-gdrive:}"
GDRIVE_SOURCE="$(prompt_default "Source do GDrive (ex.: gdrive:ROTA)" "${GDRIVE_SOURCE_DEFAULT}")"

DROPBOX_SOURCE_DEFAULT="${DROPBOX_SOURCE:-dropbox:}"
DROPBOX_SOURCE="$(prompt_default "Source do Dropbox (ex.: dropbox:EMPRESAS)" "${DROPBOX_SOURCE_DEFAULT}")"

RCLONE_UID="${RCLONE_UID:-33}"
RCLONE_GID="${RCLONE_GID:-33}"
RCLONE_DIR_CACHE_TIME="${RCLONE_DIR_CACHE_TIME:-5m}"
RCLONE_POLL_INTERVAL="${RCLONE_POLL_INTERVAL:-1m}"
RCLONE_VFS_CACHE_MAX_SIZE="${RCLONE_VFS_CACHE_MAX_SIZE:-20G}"
RCLONE_VFS_CACHE_MAX_AGE="${RCLONE_VFS_CACHE_MAX_AGE:-24h}"

RCLONE_HOME="${RCLONE_HOME:-/root}"
RCLONE_CONFIG_PATH="${RCLONE_CONFIG_PATH:-${RCLONE_HOME%/}/.config/rclone/rclone.conf}"

${SUDO} mkdir -p "${RCLONE_CACHE_DIR}" "${GDRIVE_MOUNT}" "${DROPBOX_MOUNT}"
${SUDO} mkdir -p "$(dirname "${RCLONE_CONFIG_PATH}")"

ensure_rshared() {
  local base="$1"
  if command -v findmnt >/dev/null 2>&1; then
    local prop
    prop="$(findmnt -n -o PROPAGATION "${base}" 2>/dev/null || true)"
    if [ "${prop}" != "shared" ] && [ "${prop}" != "rshared" ]; then
      echo "[info] Ajustando propagacao de mount para rshared em ${base}..."
      ${SUDO} mount --make-rshared "${base}" || true
    fi
  else
    ${SUDO} mount --make-rshared "${base}" || true
  fi
}

ensure_rshared "${RCLONE_BASE}"

write_unit() {
  local name="$1" source="$2" mountpoint="$3" unit_path="/etc/systemd/system/${name}.service"
  ${SUDO} tee "${unit_path}" >/dev/null <<EOF
[Unit]
Description=Rclone mount ${name#rclone-}
After=network-online.target
Wants=network-online.target
ConditionPathExists=${RCLONE_CONFIG_PATH}

[Service]
Type=simple
User=root
Environment=HOME=${RCLONE_HOME}
Environment=RCLONE_CONFIG=${RCLONE_CONFIG_PATH}
ExecStart=/usr/bin/rclone mount ${source} ${mountpoint} --allow-other --dir-cache-time ${RCLONE_DIR_CACHE_TIME} --poll-interval ${RCLONE_POLL_INTERVAL} --vfs-cache-mode full --vfs-cache-max-size ${RCLONE_VFS_CACHE_MAX_SIZE} --vfs-cache-max-age ${RCLONE_VFS_CACHE_MAX_AGE} --cache-dir ${RCLONE_CACHE_DIR} --umask 002 --uid ${RCLONE_UID} --gid ${RCLONE_GID} --log-file=/var/log/${name}.log --log-level INFO
ExecStop=/bin/sh -c '/bin/fusermount3 -uz ${mountpoint} || /bin/umount -l ${mountpoint}'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_unit "rclone-gdrive" "${GDRIVE_SOURCE}" "${GDRIVE_MOUNT}"
write_unit "rclone-dropbox" "${DROPBOX_SOURCE}" "${DROPBOX_MOUNT}"

${SUDO} systemctl daemon-reload
${SUDO} systemctl enable rclone-gdrive rclone-dropbox >/dev/null 2>&1 || true

update_compose() {
  local compose="${REPO_ROOT}/docker-compose.yml"
  [ -f "${compose}" ] || return 0

  local update
  update="$(prompt_default "Atualizar docker-compose.yml com mounts rclone?" "y")"
  case "${update}" in
    [Yy]*) ;;
    *) return 0 ;;
  esac

  local gdrive_line dropbox_line
  gdrive_line="      - ${GDRIVE_MOUNT}:/data/gdrive:rw,rshared"
  dropbox_line="      - ${DROPBOX_MOUNT}:/data/dropbox:rw,rshared"

  python3 - <<PY
import re
from pathlib import Path

compose = Path("${compose}")
lines = compose.read_text().splitlines()

services = {"app", "cron"}
out = []
svc = None
in_volumes = False
have_gdrive = False
have_dropbox = False

def flush_missing():
    if svc in services and in_volumes:
        if not have_gdrive:
            out.append("${gdrive_line}")
        if not have_dropbox:
            out.append("${dropbox_line}")

for line in lines:
    m = re.match(r'^  ([a-zA-Z0-9_-]+):\\s*$', line)
    if m:
        if svc in services and in_volumes:
            flush_missing()
        svc = m.group(1)
        in_volumes = False
        have_gdrive = False
        have_dropbox = False
        out.append(line)
        continue

    if svc in services and re.match(r'^    volumes:\\s*$', line):
        in_volumes = True
        out.append(line)
        continue

    if svc in services and in_volumes:
        # if we reached next key (4 spaces + non-space), close volumes
        if re.match(r'^    \\S', line) and not re.match(r'^    volumes:\\s*$', line):
            flush_missing()
            in_volumes = False
        else:
            if ':/data/gdrive' in line:
                have_gdrive = True
            if ':/data/dropbox' in line:
                have_dropbox = True

    out.append(line)

if svc in services and in_volumes:
    flush_missing()

compose.write_text("\\n".join(out) + "\\n")
PY

  echo "[ok] docker-compose.yml atualizado com mounts rclone."
}

update_compose

cat <<EOF

[ok] Systemd services criados:
  - rclone-gdrive -> ${GDRIVE_MOUNT} (source: ${GDRIVE_SOURCE})
  - rclone-dropbox -> ${DROPBOX_MOUNT} (source: ${DROPBOX_SOURCE})

Proximo passo (obrigatorio):
  1) Copie o seu rclone.conf para:
     ${RCLONE_CONFIG_PATH}
  2) Depois disso, rode:
     systemctl restart rclone-gdrive rclone-dropbox

Dicas:
  - Se quiser montar subpastas, ajuste os sources no unit file
    (ex.: gdrive:ROTA ou dropbox:EMPRESAS).
  - Para o Docker ver montagens FUSE, use volumes com :rshared
    e garanta propagacao no host (ex.: mount --make-rshared ${RCLONE_BASE}).
  - Se arquivos "somem" no container, verifique:
    * mount | grep rclone
    * findmnt -o TARGET,PROPAGATION ${RCLONE_BASE}
    * docker compose up -d --force-recreate app
    * rclone logs em /var/log/rclone-*.log

EOF
