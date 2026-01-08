# Manual de implantação - Nextcloud + OnlyOffice (LAN + TLS interno)

Stack Docker para Nextcloud + OnlyOffice usando DNS local (ex.: Mikrotik) e TLS assinado por CA interna. O tráfego externo chega via HTTPS no Nginx do host; a rede Docker `interna` fica restrita a HTTP.

## Arquitetura resumida
- Nginx no host termina TLS (`nginx/cloud.mms.conf`, `nginx/onlyoffice.mms.conf`) com cert da CA interna.
- Serviços Nextcloud: `nc-app` (Apache) e `nc-cron` (tarefas em segundo plano), com MariaDB (`nc-db`) e Redis.
- OnlyOffice Document Server com PostgreSQL (`oo-postgres`) e RabbitMQ (`oo-rabbitmq`).
- Apenas `127.0.0.1:8080` (Nextcloud) e `127.0.0.1:8082` (OnlyOffice) ficam expostos; tudo mais permanece na rede Docker `interna`.

## Script assistente (Ubuntu 22.04)
- Executa instalação do Docker/Compose, cria pastas de volumes, gera CA interna + certificado SAN, cria `.env` com senhas aleatórias, opcionalmente instala/ajusta Nginx e pode subir a stack.
- Rode na raiz do repo:
  ```bash
  bash scripts/setup-ubuntu22.sh
  ```
- Responde às perguntas (domínios, diretório base único, trusted proxies). Ele organiza tudo abaixo do diretório base (padrão `/data/nextcloud-onlyoffice`: `.../data` para volumes e `.../certs` para CA/cert). Se instalar Docker, será preciso relogar para o grupo `docker`.

## Passo a passo - Ubuntu 22.04
1. Docker/Compose
   ```bash
   sudo apt-get update
   sudo apt-get install -y ca-certificates curl gnupg lsb-release
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
   sudo apt-get update
   sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
   sudo systemctl enable --now docker
   sudo usermod -aG docker $USER   # relogar para usar sem sudo
   ```
2. Clonar o projeto e entrar na pasta:
   ```bash
   git clone <repo> nextcloud-onlyoffice-local
   cd nextcloud-onlyoffice-local
   ```
3. Criar pastas de dados/volumes (ajuste se mudar os caminhos no `.env`):
   ```bash
   sudo mkdir -p /data/nc-db /data/nc-app /data/compose/nextcloud/data
   sudo mkdir -p /data/onlyoffice/{postgres,data,logs,lib}
   sudo mkdir -p /opt/ssl/certs
   ```
4. Gerar CA interna (uma vez) e instalar em todos os clientes (Windows/macOS/Linux) e no host:
   ```bash
   openssl req -x509 -new -nodes -sha256 -days 3650 -newkey rsa:4096 \
     -keyout ca.key -out ca.crt -subj "/CN=LAN-CA"
   # importe ca.crt nos clientes (Autoridades Raiz Confiáveis)
   sudo cp ca.crt /usr/local/share/ca-certificates/lan-ca.crt
   sudo update-ca-certificates
   ```
5. Gerar certificado de servidor com SAN para os domínios (repita para cada cliente/ambiente):
   ```bash
   cat > san.cnf <<'EOF'
   [req]
   distinguished_name=req
   req_extensions=req_ext
   prompt=no
   [req_ext]
   subjectAltName=@alt_names
   [alt_names]
   DNS.1=cloud.mms
   DNS.2=onlyoffice.mms
   EOF

   openssl req -new -nodes -newkey rsa:4096 -keyout mms.key -out mms.csr \
     -subj "/CN=cloud.mms" -config san.cnf
   openssl x509 -req -in mms.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out mms.crt -days 825 -sha256 -extfile san.cnf -extensions req_ext
   sudo cp mms.crt mms.key /opt/ssl/certs/
   ```
   - Para outro cliente, troque os domínios em `san.cnf` (ex.: `cloud.cliente.local`, `onlyoffice.cliente.local`), gere novo par `*.crt`/`*.key` e ajuste o `.env`/Nginx conforme.
6. DNS interno: aponte `cloud.mms` e `onlyoffice.mms` para o IP do host no Mikrotik.
7. Configurar `.env`: `cp .env.example .env` e edite senhas, caminhos, domínios, JWT.
8. Ajustar Nginx: edite `nginx/cloud.mms.conf` e `nginx/onlyoffice.mms.conf` se mudar domínios/portas/caminhos; copie para `/etc/nginx/sites-available` e habilite no host; depois `sudo nginx -t && sudo systemctl reload nginx`.
9. Subir a stack:
   ```bash
   docker compose up -d
   docker compose ps
   ```
10. Validação final:
    - TLS: `curl -Iv https://cloud.mms` e `openssl s_client -connect cloud.mms:443 -servername cloud.mms`.
    - Nextcloud: `https://cloud.mms/status.php` e checar “Security & setup warnings”.
- OnlyOffice: `https://onlyoffice.mms/healthcheck` e teste de edição via app OnlyOffice no Nextcloud.

## Onde pegar a CA para clientes
- Por padrão, o script gera a CA em `.../certs/lan-ca.crt` dentro do diretório base (ex.: `/data/nextcloud-onlyoffice/certs/lan-ca.crt`). Copie esse arquivo para os clientes.
- Para facilitar, no host execute (ajuste se mudou o diretório base):
  ```bash
  cp /data/nextcloud-onlyoffice/certs/lan-ca.crt ~/lan-ca.crt
  ```
- Windows: executar `certmgr.msc` ou via MMC → “Trusted Root Certification Authorities” → Import → apontar para `lan-ca.crt`.
- macOS: abrir “Acesso às Chaves” → Sistema → importar `lan-ca.crt` como “Sempre confiar”.
- Linux: colocar em `/usr/local/share/ca-certificates/` e rodar `sudo update-ca-certificates`.

## OnlyOffice no Nextcloud (configuração)
- O bootstrap (`scripts/nextcloud-bootstrap.sh`) já aplica no Nextcloud:
  - Instala e habilita o app OnlyOffice (se não estiver presente).
  - `DocumentServerUrl` (externo HTTPS) a partir de `OO_PUBLIC_URL`
  - `DocumentServerInternalUrl` (HTTP na rede interna) a partir de `OO_INTERNAL_URL`
  - `StorageUrl` (URL interna do Nextcloud) a partir de `NC_INTERNAL_URL`
  - `jwt_secret` a partir de `OO_JWT_SECRET`
- Script para reaplicar a config a partir do `.env`:
  ```bash
  bash scripts/onlyoffice-config.sh
  ```
- Se precisar reaplicar manualmente (ex.: mudou domínios), rode:
  ```bash
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice DocumentServerUrl --value="https://onlyoffice.mms/"'
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://onlyoffice/"'
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice StorageUrl --value="http://app/"'
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice jwt_secret --value="SEU_JWT_AQUI"'
  ```
- Certifique-se de que o `OO_JWT_SECRET` é o mesmo no Document Server e no app OnlyOffice do Nextcloud.

## Pré-requisitos
- Docker + Docker Compose.
- DNS interno apontando `cloud.mms` e `onlyoffice.mms` para o IP do host.
- CA interna instalada em todos os clientes e no host. Gere um certificado com SAN cobrindo pelo menos `cloud.mms` e `onlyoffice.mms` e coloque em `/opt/ssl/certs/mms.crt` e `/opt/ssl/certs/mms.key`.
- Sincronização de horário ativa (NTP no Mikrotik/host) para evitar falhas de TLS/JWT.

## Configuração rápida (.env)
Copie `.env.example` para `.env` e ajuste:
- `NC_DB_ROOT_PASSWORD`, `NC_DB_PASSWORD`: senhas do MariaDB.
- Volumes (`/data/...`): paths persistentes no host para Nextcloud e OnlyOffice.
- `NC_OVERWRITE_*`: URLs externas (HTTPS) usadas pelo Nextcloud.
- `NC_TRUSTED_DOMAINS`: domínios permitidos (vírgula para múltiplos).
- `NC_TRUSTED_PROXIES`: IP do host Docker (geralmente `172.17.0.1`) e `127.0.0.1`.
- `OO_PUBLIC_URL`, `OO_INTERNAL_URL`, `NC_INTERNAL_URL`: URLs externa e internas do Document Server.
- `OO_JWT_SECRET`: segredo longo e aleatório (`openssl rand -hex 32`).
- `TZ`: timezone compartilhado pelos serviços.

## Ajuste do Nginx no host
1. Edite `nginx/cloud.mms.conf` e `nginx/onlyoffice.mms.conf` com seus domínios/caminhos de certificado e upstreams, se alterar as portas.
2. Garanta que o certificado contém os SAN corretos e é assinado pela sua CA interna.
3. Recarregue o Nginx do host após copiar as confs: `sudo nginx -t && sudo systemctl reload nginx`.

## Subir a stack
```bash
cp .env.example .env   # e edite conforme acima
docker compose up -d
```
O contêiner `nc-app` roda `scripts/nextcloud-bootstrap.sh` a cada start para padronizar as configs.

## O que o bootstrap aplica (Nextcloud)
- `overwrite.cli.url`, `overwritehost`, `overwriteprotocol`.
- `trusted_domains` e `trusted_proxies` a partir do `.env`.
- Cache/APCu e locking com Redis (`memcache.local` e `memcache.locking`).
- Config do app OnlyOffice (URLs pública/interna e `jwt_secret`).

## Validação pós-start
- TLS: `curl -Iv https://cloud.mms` e `openssl s_client -connect cloud.mms:443 -servername cloud.mms` (cadeia completa + SAN).
- Nextcloud: acessar `https://cloud.mms/status.php` e checar “Security & setup warnings” na UI.
- OnlyOffice: `https://onlyoffice.mms/healthcheck` e abrir/editar um documento pelo app OnlyOffice do Nextcloud.
- Logs úteis: `docker compose logs -f nc-app`, `nc-cron`, `onlyoffice-documentserver`.

## Backup e migração
- Volumes Nextcloud: `${NC_APP_VOLUME}` (código/config), `${NC_DATA_VOLUME}` (dados), `${NC_DB_VOLUME}` (MariaDB).
- Volumes OnlyOffice: `${OO_DATA_VOLUME}`, `${OO_LOGS_VOLUME}`, `${OO_LIB_VOLUME}`, `${OO_PG_VOLUME}`.
- Arquivos do host: `.env`, confs Nginx e certificados.
- Restaure os volumes/arquivos no novo host, ajuste o `.env` e suba com `docker compose up -d`. O bootstrap reconfigura URLs/Trusted automaticamente.

## Operação
- Atualizar imagens: `docker compose pull && docker compose up -d`.
- Cron: já roda no contêiner `nc-cron` (não use WebCron).
- Segurança: cabeçalhos HSTS/nosniff já nas confs Nginx; mantenha as portas 8080/8082 apenas no loopback ou proteja via firewall se expor.
