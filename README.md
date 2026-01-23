# Manual de implantação - Nextcloud + OnlyOffice (LAN + TLS interno)

Stack Docker para Nextcloud + OnlyOffice usando DNS local (ex.: Mikrotik) e TLS assinado por CA interna. O tráfego externo chega via HTTPS no Nginx do host; a rede Docker `interna` fica restrita a HTTP.

## Arquitetura resumida
- Nginx no host termina TLS (`nginx/cloud.axisnetworks.conf`, `nginx/onlyoffice.axisnetworks.conf` ou os nomes que você usar) com cert da CA interna ou Let's Encrypt.
- Serviços Nextcloud: `nc-app` (Apache) e `nc-cron` (tarefas em segundo plano), com MariaDB (`nc-db`) e Redis.
- OnlyOffice Document Server com PostgreSQL (`oo-postgres`) e RabbitMQ (`oo-rabbitmq`).
- Apenas `127.0.0.1:8080` (Nextcloud) e `127.0.0.1:8082` (OnlyOffice) ficam expostos; tudo mais permanece na rede Docker `interna`.

## Script assistente (Ubuntu 22.04)
- Permite instalar ou atualizar:
  - Instalação: Docker/Compose, pastas, CA interna ou Let’s Encrypt, `.env`, Nginx e subida da stack.
  - Atualização: opcional backup (scripts/backup-rclone.sh), `docker compose pull`/`up -d` e occ upgrade opcional.
- Pergunta se quer preparar um disco vazio para dados (formata/ext4 + monta em `/data` por padrão). Use só em disco vazio, pois apaga tudo.
- Pergunta o modo TLS:
  - `local`: CA interna (requer instalar a CA nos clientes).
  - `internet`: emite Let’s Encrypt (necessário domínio público + portas 80/443 abertas; usa certbot standalone e depois aplica nas confs Nginx).
- Rode na raiz do repo:
  ```bash
  bash scripts/setup-ubuntu22.sh
  ```
- Responde às perguntas (domínios, diretório base único, trusted proxies). Ele organiza tudo abaixo do diretório base (padrão `/data/nextcloud-onlyoffice`: `.../data` para volumes e `.../certs` para CA/cert). Domínios padrão sugeridos: `cloud.axisnetworks` (Nextcloud) e `onlyoffice.axisnetworks` (OnlyOffice). Se instalar Docker, será preciso relogar para o grupo `docker`.

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
   git clone https://github.com/idavinunes/nextcloud-onlyoffice-local.git
   cd nextcloud-onlyoffice-local
   # se quiser usar a imagem custom com smbclient (branch develop):
   git checkout develop
   # e subir com o override que faz o build da imagem custom:
   docker compose --env-file .env -f docker-compose.yml -f docker-compose.override.yml build app cron
   docker compose --env-file .env -f docker-compose.yml -f docker-compose.override.yml up -d app cron
   ```
3. Preparar disco de dados (recomendado)
   - Identifique o disco: `lsblk`
   - (Exemplo) Criar partição e formatar em ext4 no `/dev/sdb`:
     ```bash
     sudo parted /dev/sdb mklabel gpt
     sudo parted -a opt /dev/sdb mkpart primary ext4 0% 100%
     sudo mkfs.ext4 -L data /dev/sdb1
     ```
   - Criar ponto de montagem e montar em `/data`:
     ```bash
     sudo mkdir -p /data
     echo 'LABEL=data /data ext4 defaults 0 2' | sudo tee -a /etc/fstab
     sudo mount -a
     ```
   - Se usar outro ponto, ajuste os caminhos no `.env` ou use o setup script para gerar tudo sob um diretório base.
4. Criar pastas de dados/volumes (se não usar o script para criá-las; ajuste se mudar o diretório base):
   ```bash
   sudo mkdir -p /data/nextcloud-onlyoffice/data/nc-db
   sudo mkdir -p /data/nextcloud-onlyoffice/data/nc-app
   sudo mkdir -p /data/nextcloud-onlyoffice/data/nextcloud/data
   sudo mkdir -p /data/nextcloud-onlyoffice/data/onlyoffice/{postgres,data,logs,lib}
   sudo mkdir -p /data/nextcloud-onlyoffice/certs
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
   DNS.1=cloud.axisnetworks
   DNS.2=onlyoffice.axisnetworks
   EOF

   openssl req -new -nodes -newkey rsa:4096 -keyout axis.key -out axis.csr \
     -subj "/CN=cloud.axisnetworks" -config san.cnf
   openssl x509 -req -in axis.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out axis.crt -days 825 -sha256 -extfile san.cnf -extensions req_ext
   sudo cp axis.crt axis.key /opt/ssl/certs/
   ```
   - Para outro cliente, troque os domínios em `san.cnf` (ex.: `cloud.cliente.local`, `onlyoffice.cliente.local`), gere novo par `*.crt`/`*.key` e ajuste o `.env`/Nginx conforme.
6. DNS interno: aponte `cloud.axisnetworks` e `onlyoffice.axisnetworks` para o IP do host no Mikrotik.
7. Configurar `.env`: `cp .env.example .env` e edite senhas, caminhos, domínios, JWT.
8. Ajustar Nginx: edite `nginx/cloud.axisnetworks.conf` e `nginx/onlyoffice.axisnetworks.conf` (ou renomeie/ajuste os arquivos conforme seus domínios) se mudar domínios/portas/caminhos; copie para `/etc/nginx/sites-available` e habilite no host; depois `sudo nginx -t && sudo systemctl reload nginx`.
9. Subir a stack:
   ```bash
   docker compose up -d
   docker compose ps
   ```
10. Validação final:
    - TLS: `curl -Iv https://cloud.axisnetworks` e `openssl s_client -connect cloud.axisnetworks:443 -servername cloud.axisnetworks`.
    - Nextcloud: `https://cloud.axisnetworks/status.php` e checar “Security & setup warnings”.
    - OnlyOffice: `https://onlyoffice.axisnetworks/healthcheck` e teste de edição via app OnlyOffice no Nextcloud.

## Onde pegar a CA para clientes
- Por padrão, o script gera a CA em `.../certs/lan-ca.crt` dentro do diretório base (ex.: `/data/nextcloud-onlyoffice/certs/lan-ca.crt`). Copie esse arquivo para os clientes.
- Para facilitar, no host execute (ajuste se mudou o diretório base):
  ```bash
  cp /data/nextcloud-onlyoffice/certs/lan-ca.crt ~/lan-ca.crt
  ```
- Windows: executar `certmgr.msc` ou via MMC → “Trusted Root Certification Authorities” → Import → apontar para `lan-ca.crt`.
- macOS: abrir “Acesso às Chaves” → Sistema → importar `lan-ca.crt` como “Sempre confiar”.
- Linux: colocar em `/usr/local/share/ca-certificates/` e rodar `sudo update-ca-certificates`.

## Volumes/dados principais
- Nextcloud app/config: `${NC_APP_VOLUME}`
- Nextcloud dados: `${NC_DATA_VOLUME}`
- Nextcloud DB (MariaDB): `${NC_DB_VOLUME}`
- OnlyOffice PostgreSQL: `${OO_PG_VOLUME}`
- OnlyOffice dados/logs/lib: `${OO_DATA_VOLUME}`, `${OO_LOGS_VOLUME}`, `${OO_LIB_VOLUME}`
- `.env`: contém as senhas/segredos usados nos dumps e bootstrap.

## Backup e migração com rclone
- Script de backup (gera dumps + tar dos volumes e envia via rclone se configurado):
  ```bash
  bash scripts/backup-rclone.sh remote:backups/nextcloud-onlyoffice
  ```
  - Se não passar o remote, o backup fica em `/tmp/nc-oo-backup-<timestamp>` (ou `BACKUP_BASE=/caminho bash scripts/backup-rclone.sh`).
  - Requer `rclone` instalado se for enviar para nuvem. Caso contrário, usa apenas o backup local.
- Conteúdo do backup: dumps do MariaDB/PostgreSQL, tar.gz dos volumes e snapshot do `.env`.
- Para migrar/restaurar: pare a stack, restaure os volumes a partir dos tar.gz e reimporte os dumps nos bancos, coloque o `.env` no host e suba com `docker compose up -d`.

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
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice DocumentServerUrl --value="https://onlyoffice.axisnetworks/"'
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://onlyoffice/"'
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice StorageUrl --value="http://app/"'
  docker exec -it -u www-data nc-app bash -lc 'cd /var/www/html && php occ config:app:set onlyoffice jwt_secret --value="SEU_JWT_AQUI"'
  ```
- Certifique-se de que o `OO_JWT_SECRET` é o mesmo no Document Server e no app OnlyOffice do Nextcloud.

## WebDAV (Windows/macOS/Linux)
- Endpoint: `https://cloud.axisnetworks/remote.php/dav/files/<usuario>/`
- Use **senha de aplicativo** (Configurações > Segurança) em vez da senha da conta.
- Windows:
  - Serviço “WebClient” deve estar iniciado (`sc config WebClient start=auto` e `sc start WebClient`).
  - Se o Explorer não listar, mapeie na sessão do usuário (não admin):
    ```bat
    net use Z: https://cloud.axisnetworks/remote.php/dav/files/SEU_USUARIO/ /user:SEU_USUARIO SENHA_APP /persistent:yes
    ```
    OU via UNC:
    ```bat
    net use Z: \\cloud.axisnetworks@SSL\remote.php\dav\files\SEU_USUARIO\ /user:SEU_USUARIO SENHA_APP /persistent:yes
    ```
  - Se o Windows reclamar de revogação (CRYPT_E_NO_REVOCATION_CHECK), desabilite a checagem em Opções da Internet > Avançado ou implemente CRL/OCSP acessível para sua CA interna.
  - Se o drive mapeado não aparecer entre sessões elevadas/normais, habilite `EnableLinkedConnections=1` em `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` e reinicie.
- macOS: Finder > Conectar ao servidor > `https://cloud.axisnetworks/remote.php/dav/files/SEU_USUARIO/`, use senha de app.
- Linux: `davfs2` ou `curl`/`cadaver` com a mesma URL e senha de app.

## Armazenamento externo (SMB/CIFS)
- Ative o app “Armazenamento Externo” (files_external) no Nextcloud.
- Para montar shares SMB, instale as libs SMB no contêiner (precisa repetir após atualizar a imagem, ou crie sua imagem customizada):
  ```bash
  DOCKER_BIN="docker" bash scripts/install-smbclient.sh   # se precisar de sudo: DOCKER_BIN="sudo docker" bash ...
  ```
- Se o `apt` não encontrar `php-smbclient`/`php-pear`, use uma imagem do Nextcloud baseada em Debian estável: defina `NC_IMAGE=nextcloud:29-apache` (ou outra tag estável disponível, ex. `nextcloud:apache-bullseye`) no `.env` e recrie `app/cron`.
- Branch develop: já existe um override (`docker-compose.override.yml`) que builda a imagem `nextcloud:32-apache-smb` com o smbclient pré-instalado. Para usar:
  ```bash
  # em ambiente de teste
  git checkout develop && git pull
  docker compose --env-file .env -f docker-compose.yml -f docker-compose.override.yml build app cron
  docker compose --env-file .env -f docker-compose.yml -f docker-compose.override.yml up -d app cron
  docker exec -u www-data nc-app php -m | grep smbclient   # deve mostrar smbclient
  ```
- Configure o mount na UI de admin (Configurações > Administração > Armazenamento externo): tipo SMB/CIFS, host/share, usuário/senha, pasta de montagem e visibilidade.
- Se preferir montar o storage no host e usá-lo como dados principais, aponte `NC_DATA_VOLUME` para esse mount, mas garanta estabilidade da rede/storage; cotas do Nextcloud só se aplicam ao storage local/data dir.

### Fulltextsearch (opcional, override develop)
- No override `docker-compose.override.yml` há um serviço `elasticsearch` (rede interna, sem portas expostas). Ajuste `ES_DATA_VOLUME` no `.env` se quiser persistir.
- Instale/ative os apps:
  ```bash
  docker exec -u www-data nc-app php occ app:install fulltextsearch fulltextsearch_elasticsearch files_fulltextsearch
  docker exec -u www-data nc-app php occ app:enable fulltextsearch fulltextsearch_elasticsearch files_fulltextsearch
  ```
- Configure o backend (usando o serviço interno):
  ```bash
  docker exec -u www-data nc-app php occ config:app:set fulltextsearch platform --value "OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"
  docker exec -u www-data nc-app php occ config:app:set fulltextsearch_elasticsearch servers --value "http://elasticsearch:9200"
  ```
- Indexe:
  ```bash
  docker exec -u www-data nc-app php occ fulltextsearch:index
  ```
  Para produção, habilite TLS/usuário no Elasticsearch e ajuste a URL/verify na configuração.

## Apps recomendados (instalação rápida)
- Script para instalar/ativar apps base (ajuste a lista em `scripts/install-apps-base.sh`):
  ```bash
  bash scripts/install-apps-base.sh
  ```
- Lista padrão no script: `logreader`, `admin_audit`, `files_external`, `external` (Sites externos), `client_push`, `groupfolders`.
- Para SMB, rode antes `bash scripts/install-smbclient.sh` (instala libs SMB no contêiner).
- Busca full-text (opcional): requer subir Solr/Elasticsearch e instalar `fulltextsearch` + `fulltextsearch_files` (não automatizado aqui).
- Impersonate (acessar a conta de um usuário para suporte/limpeza de arquivos): admin pode instalar/ativar com
  ```bash
  docker exec -u www-data nc-app php occ app:install impersonate
  docker exec -u www-data nc-app php occ app:enable impersonate
  ```
  Depois, na UI (Configurações → Usuários), no menu “…” de um usuário escolha **Impersonar**. Saia para voltar à sua sessão. Por padrão, só admin pode usar; restrinja/autorize grupos em Configurações → Segurança → Impersonate.

### Ajuste de brute force para redes internas
- Para evitar atraso em logins na LAN, isente suas sub-redes e limpe tentativas pendentes:
  ```bash
  sudo docker exec -u www-data nc-app php occ config:system:set auth.bruteforce.protection.exempt_subnets --value="192.168.10.0/24,192.168.11.0/24,192.168.12.0/24,192.168.13.0/24,192.168.14.0/24,192.168.254.0/24,172.255.255.0/24"
  source .env
  sudo docker exec nc-db mariadb -u"$NC_DB_USER" -p"$NC_DB_PASSWORD" "$NC_DB_NAME" -e "TRUNCATE TABLE oc_bruteforce_attempts;"
  ```

## Pré-requisitos
- Docker + Docker Compose.
- DNS interno apontando `cloud.axisnetworks` e `onlyoffice.axisnetworks` para o IP do host.
- CA interna instalada em todos os clientes e no host. Gere um certificado com SAN cobrindo pelo menos `cloud.axisnetworks` e `onlyoffice.axisnetworks` e coloque em `/opt/ssl/certs/axis.crt` e `/opt/ssl/certs/axis.key` (ou use os caminhos/prefixos que preferir).
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
1. Edite `nginx/cloud.axisnetworks.conf` e `nginx/onlyoffice.axisnetworks.conf` (ou ajuste/renomeie conforme seus domínios) com seus domínios/caminhos de certificado e upstreams, se alterar as portas.
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
- TLS: `curl -Iv https://cloud.axisnetworks` e `openssl s_client -connect cloud.axisnetworks:443 -servername cloud.axisnetworks` (cadeia completa + SAN).
- Nextcloud: acessar `https://cloud.axisnetworks/status.php` e checar “Security & setup warnings” na UI.
- OnlyOffice: `https://onlyoffice.axisnetworks/healthcheck` e abrir/editar um documento pelo app OnlyOffice do Nextcloud.
- Logs úteis: `docker compose logs -f nc-app`, `nc-cron`, `onlyoffice-documentserver`.

## Backup e migração
- Volumes Nextcloud: `${NC_APP_VOLUME}` (código/config), `${NC_DATA_VOLUME}` (dados), `${NC_DB_VOLUME}` (MariaDB).
- Volumes OnlyOffice: `${OO_DATA_VOLUME}`, `${OO_LOGS_VOLUME}`, `${OO_LIB_VOLUME}`, `${OO_PG_VOLUME}`.
- Arquivos do host: `.env`, confs Nginx e certificados.
- Restaure os volumes/arquivos no novo host, ajuste o `.env` e suba com `docker compose up -d`. O bootstrap reconfigura URLs/Trusted automaticamente.

## Upgrade do stack
- Automatizado: `bash scripts/setup-ubuntu22.sh` e escolha “atualizar” (backup opcional, `docker compose pull`/`up -d` e `occ upgrade`).
- Manual:
  ```bash
  docker compose pull
  docker compose up -d
  sudo docker exec -u www-data nc-app php occ upgrade   # se Nextcloud foi atualizado
  sudo docker exec -u www-data nc-app php occ maintenance:mode --off  # se necessário
  ```
- `upgrade.disable-web` permanece ativo por segurança; use o upgrade via CLI.

## Operação
- Atualizar imagens: `docker compose pull && docker compose up -d`.
- Cron: já roda no contêiner `nc-cron` (não use WebCron).
- Segurança: cabeçalhos HSTS/nosniff já nas confs Nginx; mantenha as portas 8080/8082 apenas no loopback ou proteja via firewall se expor.
