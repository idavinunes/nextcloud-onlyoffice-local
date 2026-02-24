#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [ ! -f "docker-compose.yml" ]; then
  echo "Este script precisa ser executado na raiz do repositório (onde está o docker-compose.yml)." >&2
  exit 1
fi

OS_ID="$(. /etc/os-release && echo "${ID:-}")"
OS_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-}")"
if [ "${OS_ID}" != "ubuntu" ] || [ "${OS_VERSION%%.*}" != "22" ]; then
  echo "Aviso: alvo testado é Ubuntu 22.04; detectado ${OS_ID} ${OS_VERSION}." >&2
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Instale sudo ou execute como root." >&2
    exit 1
  fi
fi

ask_yes_no() {
  local prompt="$1" default="${2:-n}" reply suffix="[y/N]"
  [ "${default}" = "y" ] && suffix="[Y/n]"
  read -r -p "${prompt} ${suffix} " reply || true
  reply="${reply:-${default}}"
  case "${reply}" in
    [Yy]) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_default() {
  local prompt="$1" default="$2" reply
  read -r -p "${prompt} [${default}]: " reply || true
  echo "${reply:-${default}}"
}

prepare_data_disk() {
  if ! ask_yes_no "Preparar um disco vazio para dados (FORMATA E APAGA TUDO)? " "n"; then
    return
  fi

  if ! command -v parted >/dev/null 2>&1; then
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y parted
  fi

  echo "[info] Discos disponíveis:"
  ${SUDO} lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

  local device part mountpoint label
  device="$(prompt_default "Dispositivo para formatar (ex.: /dev/sdb)" "")"
  if [ -z "${device}" ] || [ ! -b "${device}" ]; then
    echo "[warn] Dispositivo inválido; pulando preparo de disco."
    return
  fi

  # monta nome da partição (sdb1 vs nvme0n1p1)
  part="${device}1"
  case "${device}" in
    *[0-9]) part="${device}p1" ;;
  esac

  mountpoint="$(prompt_default "Ponto de montagem" "/data")"
  label="$(prompt_default "Label do filesystem" "data")"

  echo "[alerta] Isso VAI apagar TODO o conteúdo de ${device}."
  if ! ask_yes_no "Confirmar formatação de ${device} (partição ${part})? " "n"; then
    echo "[warn] Cancelado pelo usuário."
    return
  fi

  ${SUDO} umount -f "${device}" "${part}" >/dev/null 2>&1 || true
  ${SUDO} parted -s "${device}" mklabel gpt
  ${SUDO} parted -s -a opt "${device}" mkpart primary ext4 0% 100%
  ${SUDO} partprobe "${device}" >/dev/null 2>&1 || true
  if command -v udevadm >/dev/null 2>&1; then
    ${SUDO} udevadm settle
  fi
  for _ in 1 2 3 4 5; do
    [ -b "${part}" ] && break
    sleep 1
  done
  if [ ! -b "${part}" ]; then
    echo "[error] Partição ${part} não encontrada após particionar ${device}. Tente reiniciar e rodar novamente."
    return 1
  fi
  ${SUDO} mkfs.ext4 -F -L "${label}" "${part}"

  ${SUDO} mkdir -p "${mountpoint}"
  if ! grep -q "LABEL=${label}[[:space:]]\+${mountpoint}[[:space:]]\+ext4" /etc/fstab 2>/dev/null; then
    echo "LABEL=${label} ${mountpoint} ext4 defaults 0 2" | ${SUDO} tee -a /etc/fstab >/dev/null
  else
    echo "[warn] Entrada com LABEL=${label} já existe em /etc/fstab; mantendo."
  fi
  ${SUDO} mount -a
  echo "[ok] Disco preparado e montado em ${mountpoint}"
}

DOCKER_BIN="docker"
[ -n "${SUDO}" ] && DOCKER_BIN="${SUDO} docker"

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "[ok] Docker e compose plugin já instalados."
    return
  fi
  if ask_yes_no "Instalar Docker e plugin compose?" "y"; then
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | ${SUDO} gpg --dearmor -o /usr/share/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    ${SUDO} systemctl enable --now docker
    if [ -n "${SUDO}" ]; then
      ${SUDO} usermod -aG docker "${USER}"
      echo "[info] Adicionado ${USER} ao grupo docker (faça logout/login para efeito)."
    fi
  else
    echo "[warn] Docker não instalado; abortando."
    exit 1
  fi
}

detect_docker_cmd() {
  DOCKER_BIN="docker"
  if ! ${DOCKER_BIN} info >/dev/null 2>&1; then
    if [ -n "${SUDO}" ]; then
      echo "[warn] Sem acesso ao docker.sock; usando sudo docker."
      DOCKER_BIN="${SUDO} docker"
    else
      echo "[error] Sem acesso ao docker.sock. Faça logout/login para aplicar o grupo docker ou rode com sudo." >&2
      exit 1
    fi
  fi
}

ensure_network() {
  local net_name="interna"
  if ! ${DOCKER_BIN} network inspect "${net_name}" >/dev/null 2>&1; then
    echo "[info] Criando rede docker ${net_name} (external)..."
    ${DOCKER_BIN} network create "${net_name}"
  else
    echo "[ok] Rede docker ${net_name} já existe."
  fi
}

update_stack() {
  echo "=== Atualização ==="
  ensure_docker
  detect_docker_cmd
  ensure_network

  if ask_yes_no "Rodar backup (scripts/backup-rclone.sh) antes de atualizar?" "y"; then
    read -r -p "Destino rclone (ex.: remote:backups/nc-oo) [vazio = só local]: " remote_target || true
    if [ -x "${REPO_ROOT}/scripts/backup-rclone.sh" ]; then
      BACKUP_BASE="${BACKUP_BASE:-/tmp}" bash "${REPO_ROOT}/scripts/backup-rclone.sh" "${remote_target}"
    else
      echo "[warn] Script de backup não encontrado em scripts/backup-rclone.sh; pulando."
    fi
  fi

  echo "[info] Atualizando imagens..."
  ${DOCKER_BIN} compose pull
  echo "[info] Subindo stack..."
  ${DOCKER_BIN} compose up -d

  if ask_yes_no "Rodar occ upgrade (recomendado se Nextcloud foi atualizado)?" "y"; then
    ${DOCKER_BIN} exec -u www-data nc-app php occ upgrade || true
  fi

  echo "[ok] Atualização concluída."
  exit 0
}

create_dirs() {
  local dirs=("$@")
  for dir in "${dirs[@]}"; do
    ${SUDO} mkdir -p "${dir}"
  done
}

ensure_acl_tool() {
  if command -v setfacl >/dev/null 2>&1; then
    return
  fi
  echo "[info] Instalando suporte a ACL (acl) para acesso via host..."
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y acl
}

grant_host_access() {
  local target_dir="$1" host_user="$2"
  ensure_acl_tool
  if [ -z "${host_user}" ]; then
    return
  fi
  if ! id -u "${host_user}" >/dev/null 2>&1; then
    return
  fi
  echo "[info] Concedendo ACL para ${host_user} em ${target_dir}"
  if ! ${SUDO} setfacl -R -m "u:${host_user}:rwX" "${target_dir}"; then
    echo "[warn] Não foi possível aplicar ACL em ${target_dir} (filesystem suporta ACL?)." >&2
  fi
  if ! ${SUDO} setfacl -d -m "u:${host_user}:rwX" "${target_dir}"; then
    echo "[warn] Não foi possível aplicar ACL default em ${target_dir}." >&2
  fi
}

ensure_wwwdata_owner() {
  local dirs=("$@")
  for dir in "${dirs[@]}"; do
    ${SUDO} chown -R 33:33 "${dir}" 2>/dev/null || true
    ${SUDO} chmod 0770 "${dir}" 2>/dev/null || true
  done
}

render_san_cfg() {
  local file="$1" domains_csv="$2" idx=1
  {
    echo "[req]"
    echo "distinguished_name=req"
    echo "req_extensions=req_ext"
    echo "prompt=no"
    echo "[req_ext]"
    echo "subjectAltName=@alt_names"
    echo "[alt_names]"
    IFS=',' read -r -a doms <<<"${domains_csv}"
    for d in "${doms[@]}"; do
      d_clean="$(echo "${d}" | xargs)"
      if [ -n "${d_clean}" ]; then
        echo "DNS.${idx}=${d_clean}"
        idx=$((idx + 1))
      fi
    done
  } > "${file}"
}

generate_ca_and_cert() {
  local cert_dir="$1" domains_csv="$2"
  if ! ask_yes_no "Gerar CA interna e certificado de servidor (SAN)?" "y"; then
    return
  fi

  ${SUDO} mkdir -p "${cert_dir}"
  local ca_key="${cert_dir}/lan-ca.key"
  local ca_crt="${cert_dir}/lan-ca.crt"
  local srv_key="${cert_dir}/mms.key"
  local srv_crt="${cert_dir}/mms.crt"

  if [ -f "${ca_key}" ] || [ -f "${ca_crt}" ]; then
    if ask_yes_no "CA existente detectada em ${cert_dir}. Substituir?" "n"; then
      ${SUDO} rm -f "${ca_key}" "${ca_crt}"
    else
      echo "[info] Mantendo CA existente."
    fi
  fi

  if [ ! -f "${ca_key}" ] || [ ! -f "${ca_crt}" ]; then
    ${SUDO} openssl req -x509 -new -nodes -sha256 -days 3650 -newkey rsa:4096 \
      -keyout "${ca_key}" -out "${ca_crt}" -subj "/CN=LAN-CA"
    ${SUDO} chmod 600 "${ca_key}"
    echo "[ok] CA gerada em ${ca_crt}."
  fi

  local san_cfg
  san_cfg="$(mktemp)"
  render_san_cfg "${san_cfg}" "${domains_csv}"
  local cn
  cn="$(echo "${domains_csv}" | cut -d',' -f1 | xargs)"

  ${SUDO} openssl req -new -nodes -newkey rsa:4096 -keyout "${srv_key}" -out "${cert_dir}/mms.csr" \
    -subj "/CN=${cn}" -config "${san_cfg}"
  ${SUDO} openssl x509 -req -in "${cert_dir}/mms.csr" -CA "${ca_crt}" -CAkey "${ca_key}" -CAcreateserial \
    -CAserial "${cert_dir}/lan-ca.srl" \
    -out "${srv_crt}" -days 825 -sha256 -extfile "${san_cfg}" -extensions req_ext
  ${SUDO} chmod 600 "${srv_key}"
  ${SUDO} rm -f "${cert_dir}/mms.csr" "${cert_dir}/lan-ca.srl" "${san_cfg}"
  echo "[ok] Certificado emitido em ${srv_crt} com SAN: ${domains_csv}."

  if ask_yes_no "Instalar CA no trust store do host (update-ca-certificates)?" "y"; then
    ${SUDO} cp "${ca_crt}" /usr/local/share/ca-certificates/lan-ca.crt
    ${SUDO} update-ca-certificates
  fi

  if [ -n "${HOME:-}" ]; then
    ${SUDO} cp "${ca_crt}" "${HOME}/lan-ca.crt"
    [ -n "${SUDO}" ] && ${SUDO} chown "$(id -u):$(id -g)" "${HOME}/lan-ca.crt"
    echo "[ok] CA copiada para ${HOME}/lan-ca.crt (importação em navegadores/clientes)."
  fi
}

obtain_lets_encrypt_cert() {
  local cloud_domain="$1" oo_domain="$2"
  local email
  email="$(prompt_default "E-mail para Let's Encrypt (avisos de expiração)" "")"

  if ! ask_yes_no "Emitir certificado Let's Encrypt (requer portas 80/443 públicas)?" "y"; then
    echo "[warn] Let's Encrypt não solicitado; abortando modo internet."
    exit 1
  fi

  ${SUDO} apt-get update
  ${SUDO} apt-get install -y certbot

  echo "[info] Parando Nginx (se rodando) para validação standalone..."
  ${SUDO} systemctl stop nginx 2>/dev/null || true

  local blockers
  blockers="$(${SUDO} ss -ltnp 2>/dev/null | grep -E ':80\\b|:443\\b' || true)"
  if [ -n "${blockers}" ]; then
    echo "[error] Portas 80/443 ainda estão em uso; libere antes de prosseguir (Let's Encrypt precisa dessas portas)." >&2
    echo "${blockers}"
    echo "[hint] Pare serviços/listeners acima (ex.: apache2/nginx/outro container) ou escolha o modo TLS 'local' para usar CA interna." >&2
    exit 1
  fi

  local email_opts="--register-unsafely-without-email"
  [ -n "${email}" ] && email_opts="-m ${email} --agree-tos"

  if ! ${SUDO} certbot certonly --standalone --non-interactive ${email_opts} -d "${cloud_domain}" -d "${oo_domain}"; then
    echo "[error] Falha ao emitir certificado Let's Encrypt. Verifique DNS e portas 80/443." >&2
    exit 1
  fi

  echo "[info] Reiniciando Nginx (se aplicável)..."
  ${SUDO} systemctl start nginx 2>/dev/null || true
}

render_nginx_conf() {
  local template="$1" domain="$2" cert_path="$3" key_path="$4" output="$5"
  ${SUDO} sed \
    -e "s/cloud\\.mms/${domain}/g" \
    -e "s/onlyoffice\\.mms/${domain}/g" \
    -e "s#/opt/ssl/certs/mms.crt#${cert_path}#g" \
    -e "s#/opt/ssl/certs/mms.key#${key_path}#g" \
    "${template}" | ${SUDO} tee "${output}" >/dev/null
}

configure_nginx() {
  local cloud_domain="$1" oo_domain="$2" cert_path="$3" key_path="$4" mode="$5"
  if [ "${SKIP_NGINX_CONFIG:-}" = "1" ]; then
    echo "[info] SKIP_NGINX_CONFIG=1 — pulando configuração do Nginx."
    return
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y nginx
  fi
  local avail="/etc/nginx/sites-available"
  local enabled="/etc/nginx/sites-enabled"
  ${SUDO} mkdir -p "${avail}" "${enabled}"

  local cloud_tpl="${REPO_ROOT}/nginx/cloud.mms.conf"
  local oo_tpl="${REPO_ROOT}/nginx/onlyoffice.mms.conf"
  if [ "${mode}" = "http" ]; then
    cloud_tpl="${REPO_ROOT}/nginx/cloud.mms.http.conf"
    oo_tpl="${REPO_ROOT}/nginx/onlyoffice.mms.http.conf"
  fi

  render_nginx_conf "${cloud_tpl}" "${cloud_domain}" "${cert_path}" "${key_path}" "${avail}/${cloud_domain}.conf"
  render_nginx_conf "${oo_tpl}" "${oo_domain}" "${cert_path}" "${key_path}" "${avail}/${oo_domain}.conf"

  ${SUDO} ln -sf "${avail}/${cloud_domain}.conf" "${enabled}/${cloud_domain}.conf"
  ${SUDO} ln -sf "${avail}/${oo_domain}.conf" "${enabled}/${oo_domain}.conf"
  ${SUDO} nginx -t
  ${SUDO} systemctl reload nginx
  echo "[ok] Nginx configurado para ${cloud_domain} e ${oo_domain}."
}

generate_env_file() {
  local env_file=".env"
  local cloud_domain="$1" oo_domain="$2" data_root="$3" cert_dir="$4" tz_value="$5" proxies="$6"
  if [ -f "${env_file}" ]; then
    if ! ask_yes_no ".env já existe. Substituir?" "n"; then
      echo "[info] Mantendo .env existente."
      return
    fi
  fi

  local db_root db_pass jwt_secret
  db_root="$(openssl rand -hex 16)"
  db_pass="$(openssl rand -hex 16)"
  jwt_secret="$(openssl rand -hex 32)"

  cat > "${env_file}" <<EOF
TZ=${tz_value}
NEXTCLOUD_IMAGE=${NEXTCLOUD_IMAGE:-nextcloud:31-apache}
NC_HTTP_PORT=8080
OO_HTTP_PORT=8082

  NC_DB_ROOT_PASSWORD=${db_root}
  NC_DB_NAME=nextcloud
  NC_DB_USER=ncuser
  NC_DB_PASSWORD=${db_pass}

  NC_DB_VOLUME=${data_root}/nc-db
  NC_APP_VOLUME=${data_root}/nc-app
  NC_DATA_VOLUME=${data_root}/nc-data

  OO_PG_VOLUME=${data_root}/oo-pg
  OO_DATA_VOLUME=${data_root}/oo-data
  OO_LOGS_VOLUME=${data_root}/oo-logs
  OO_LIB_VOLUME=${data_root}/oo-lib

NC_OVERWRITE_CLI_URL=https://${cloud_domain}
NC_OVERWRITE_HOST=${cloud_domain}
NC_OVERWRITE_PROTOCOL=https
NC_TRUSTED_DOMAINS=${cloud_domain}
NC_TRUSTED_PROXIES=${proxies}

OO_PUBLIC_URL=https://${oo_domain}/
OO_INTERNAL_URL=http://onlyoffice/
NC_INTERNAL_URL=http://app/
OO_JWT_SECRET=${jwt_secret}
NEXTCLOUD_ADMIN_USER=${admin_user}
NEXTCLOUD_ADMIN_PASSWORD=${admin_pass}
NC_DEFAULT_PHONE_REGION=${phone_region}
EOF
  echo "[ok] .env gerado com senhas/segredos aleatórios."
}

bring_up_stack() {
  if ask_yes_no "Subir stack agora com docker compose up -d?" "y"; then
    ${DOCKER_BIN} compose up -d
  else
    echo "[info] Stack não iniciada; execute 'docker compose up -d' quando pronto."
  fi
}

main() {
  echo "=== Parâmetros ==="
  local action cloud_domain oo_domain base_dir data_root cert_dir tz_value proxies tls_mode cert_path key_path host_user admin_user admin_pass phone_region proxy_profile
  action="$(prompt_default "Ação (instalar|atualizar)" "instalar")"
  if [ "${action}" = "atualizar" ]; then
    update_stack
  fi

  cloud_domain="$(prompt_default "Domínio do Nextcloud" "cloud.axisnetworks")"
  oo_domain="$(prompt_default "Domínio do OnlyOffice" "onlyoffice.axisnetworks")"
  base_dir="$(prompt_default "Diretório base único (dados/certs)" "/data/nc-oo")"
  data_root="${base_dir}"
  cert_dir="${base_dir}/certs"
  tz_value="$(prompt_default "Timezone (TZ)" "America/Sao_Paulo")"
  proxies="$(prompt_default "trusted_proxies (CSV)" "172.17.0.1,127.0.0.1")"
  tls_mode="$(prompt_default "Modo TLS (local|internet)" "internet")"
  proxy_profile="$(prompt_default "Perfil de proxy (internet|local|cloudflare)" "internet")"
  host_user="${SUDO_USER:-${USER}}"
  admin_user="$(prompt_default "Criar admin automaticamente? Usuário (vazio = configurar via UI)" "")"
  admin_pass=""
  if [ -n "${admin_user}" ]; then
    read -r -s -p "Senha do admin: " admin_pass || true
    echo
  fi
  phone_region="$(prompt_default "default_phone_region (código ISO, ex.: BR)" "BR")"

  # Perfil cloudflare: não gera certificado local (TLS fica no edge/túnel).
  local nginx_mode="https"
  if [ "${proxy_profile}" = "cloudflare" ]; then
    tls_mode="cloudflare"
    nginx_mode="http"
  fi

  if [ "${tls_mode}" = "local" ] && [ "${proxy_profile}" != "cloudflare" ]; then
    if ! echo "${cloud_domain}" | grep -Eiq '\.(local|lan)$'; then
      if ! ask_yes_no "Você escolheu 'local' com domínio público (${cloud_domain}). Isso usará CA interna e exigirá instalar a CA nos clientes. Continuar?" "n"; then
        tls_mode="internet"
      fi
    fi
  fi

  prepare_data_disk
  ensure_docker
  detect_docker_cmd
  ensure_network
  create_dirs "${data_root}/nc-db" "${data_root}/nc-app" "${data_root}/nc-data" \
    "${data_root}/oo-pg" "${data_root}/oo-data" "${data_root}/oo-logs" \
    "${data_root}/oo-lib" "${cert_dir}"
  ensure_wwwdata_owner "${data_root}/nc-app" "${data_root}/nc-data"
  grant_host_access "${data_root}/nc-data" "${host_user}"

  if [ "${tls_mode}" = "internet" ]; then
    obtain_lets_encrypt_cert "${cloud_domain}" "${oo_domain}"
    cert_path="/etc/letsencrypt/live/${cloud_domain}/fullchain.pem"
    key_path="/etc/letsencrypt/live/${cloud_domain}/privkey.pem"
    if [ ! -f "${cert_path}" ] || [ ! -f "${key_path}" ]; then
      echo "[error] Certificados Let's Encrypt não encontrados em ${cert_path}/${key_path}." >&2
      exit 1
    fi
  elif [ "${tls_mode}" = "local" ]; then
    generate_ca_and_cert "${cert_dir}" "${cloud_domain},${oo_domain}"
    cert_path="${cert_dir}/mms.crt"
    key_path="${cert_dir}/mms.key"
  else
    # cloudflare: usa HTTP local, TLS no edge; sem certificados aqui
    cert_path=""
    key_path=""
  fi

  generate_env_file "${cloud_domain}" "${oo_domain}" "${data_root}" "${cert_dir}" "${tz_value}" "${proxies}"
  configure_nginx "${cloud_domain}" "${oo_domain}" "${cert_path}" "${key_path}" "${nginx_mode}"

  if [ "${proxy_profile}" = "cloudflare" ]; then
    if [ -f "${REPO_ROOT}/scripts/cloudflare-realip.sh" ]; then
      echo "[info] Aplicando real_ip da Cloudflare..."
      chmod +x "${REPO_ROOT}/scripts/cloudflare-realip.sh" 2>/dev/null || true
      SUDO="${SUDO}" bash "${REPO_ROOT}/scripts/cloudflare-realip.sh"
    else
      echo "[warn] scripts/cloudflare-realip.sh não encontrado; aplique manualmente o real_ip para Cloudflare."
    fi
    echo "[info] Cloudflare/túnel: este setup não instala nem registra o cloudflared."
    echo "[info] Instale e configure o cloudflared no host (fora do Docker) conforme README."
  fi

  echo "=== Resumo ==="
  echo "Domínios: NC=${cloud_domain}, OO=${oo_domain}"
  echo "Base: ${base_dir}"
  echo "Volumes em: ${data_root}"
  case "${tls_mode}" in
    internet)
      echo "Certificados: ${cert_path} | ${key_path} (Let's Encrypt)"
      ;;
    local)
      echo "Certificados: ${cert_path}|${key_path} (CA: ${cert_dir}/lan-ca.crt)"
      ;;
    cloudflare)
      echo "Certificados: origem HTTP (sem TLS local); TLS termina no Cloudflare/túnel"
      ;;
  esac
  echo ".env gerado (revise senhas/URLs se necessário)"

  bring_up_stack

  cat <<EOF
=== Próximos testes ===
- TLS: curl -Iv https://${cloud_domain} e openssl s_client -connect ${cloud_domain}:443 -servername ${cloud_domain}
- Nextcloud: https://${cloud_domain}/status.php e “Security & setup warnings”
- OnlyOffice: https://${oo_domain}/healthcheck e edição via app OnlyOffice no Nextcloud
 - Cloudflare: verifique o serviço cloudflared no host (systemctl status cloudflared) e logs (journalctl -u cloudflared -n 100)
EOF
}

main "$@"
