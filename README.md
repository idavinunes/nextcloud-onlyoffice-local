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
- Para Let’s Encrypt, libere as portas 80/443 no host (pare Nginx/Apache/containers que estejam escutando) antes de rodar o setup; se não puder parar, use o modo `local`.
- Rode na raiz do repo:
  ```bash
  bash scripts/setup-ubuntu22.sh
  ```
- Responde às perguntas (domínios, diretório base único, trusted proxies). Ele organiza tudo abaixo do diretório base (padrão `/data/nc-oo`: volumes na raiz e `.../certs` para CA/cert). Domínios padrão sugeridos: `cloud.axisnetworks` (Nextcloud) e `onlyoffice.axisnetworks` (OnlyOffice). Se instalar Docker, será preciso relogar para o grupo `docker`.
- Para evitar pegar releases muito novas, o `.env` gerado já define `NEXTCLOUD_IMAGE=nextcloud:29-apache` (estável suportada). Se quiser atualizar depois, altere manualmente para `nextcloud:apache` ou a tag desejada e rode `docker compose pull && docker compose up -d`. **Não faça downgrade de versão já instalada**.
- Perfis de proxy (prompt do setup):
  - `internet`: uso padrão com domínio público (pode usar Let’s Encrypt).
  - `local`: TLS com CA interna para LAN.
  - `cloudflare`: pensado para túnel Cloudflare/Argo. Não gera certificado local nem roda certbot; configura Nginx só em HTTP (127.0.0.1:8080/8082), aplica real IP da Cloudflare e oferece passo opcional para colar o token `cloudflared service install ...`.

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
   sudo mkdir -p /data/nc-oo/{nc-db,nc-app,nc-data,oo-pg,oo-data,oo-logs,oo-lib,certs}
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
- Por padrão, o script gera a CA em `.../certs/lan-ca.crt` dentro do diretório base (ex.: `/data/nc-oo/certs/lan-ca.crt`). Copie esse arquivo para os clientes.
- Para facilitar, no host execute (ajuste se mudou o diretório base):
  ```bash
  cp /data/nc-oo/certs/lan-ca.crt ~/lan-ca.crt
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
- Padrão do setup script: diretório base `/data/nc-oo` com volumes achatados (`nc-db`, `nc-app`, `nc-data`, `oo-pg`, `oo-data`, `oo-logs`, `oo-lib`) e certs em `.../certs`.
- O setup aplica `chown 33:33` em `nc-app`/`nc-data` e tenta dar ACL de leitura/escrita para o usuário que executa o script (para backup via host/rclone). Em filesystems sem ACL (ex.: CIFS sem suporte), monte com `uid=33,gid=33,file_mode=0770,dir_mode=0770` ou ajuste as opções de mount conforme a seção de CIFS abaixo.

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
- Configure o mount na UI de admin (Configurações > Administração > Armazenamento externo): tipo SMB/CIFS, host/share, usuário/senha, pasta de montagem e visibilidade.
- Se preferir montar o storage no host e usá-lo como dados principais, aponte `NC_DATA_VOLUME` para esse mount, mas garanta estabilidade da rede/storage; cotas do Nextcloud só se aplicam ao storage local/data dir.
- Para ambientes locais usando CIFS montado no host, faça o mount no host e só repasse a pasta para o contêiner. Exemplo:
  ```bash
  sudo mkdir -p /mnt/ncdata
  # Use credfile para não deixar senha em texto: cat >/root/.smb-cred <<EOF\nusername=USUARIO\npassword=SENHA\nEOF\nchmod 600 /root/.smb-cred
  sudo mount -t cifs //srvarquivos/share /mnt/ncdata \
    -o vers=3.0,credentials=/root/.smb-cred,uid=33,gid=33,file_mode=0770,dir_mode=0770
  ```
  Depois ajuste `NC_DATA_VOLUME=/mnt/ncdata` no `.env` e rode `docker compose up -d` (ou um override de volume) para usar esse caminho dentro do contêiner.

## Apps recomendados (instalação rápida)
- Script para instalar/ativar apps base (ajuste a lista em `scripts/install-apps-base.sh`):
  ```bash
  bash scripts/install-apps-base.sh
  ```
- Lista padrão no script: `logreader`, `admin_audit`, `files_external`, `external` (Sites externos), `groupfolders`, `analytics`, `bruteforcesettings`, `calendar`, `contacts`, `mail`, `monitoring`, `notifications`, `password_policy`, `passwords`, `photos`, `privacy`, `recommendations`, `text`, `twofactor_totp`, `user_status`, `versions`, `weather_status`.
- Para SMB, rode antes `bash scripts/install-smbclient.sh` (instala libs SMB no contêiner).
- Busca full-text (opcional): requer subir Solr/Elasticsearch e instalar `fulltextsearch` + `fulltextsearch_files` (não automatizado aqui).

## Pós-instalação rápida (avisos comuns)
- Script para resolver avisos frequentes (Client Push, notifications, janela de manutenção, reparos caros):
  ```bash
  bash scripts/postinstall-fixes.sh   # usa nc-app como contêiner padrão
  ```
- Ajuste `MAINT_WINDOW_START` no `.env` se quiser outro horário (padrão 1 = 01:00).
- O script também instala `app_api` e lembra sobre configurar o daemon (Ex-Apps), Talk HPB/TURN e cabeçalhos Forwarded (necessários no proxy). Se o client_push falhar na appstore, ele tenta fallback com tarball (detecta a versão do Nextcloud e escolhe a release adequada; permite sobrescrever com `CLIENT_PUSH_VER=...`). Se a URL não existir, apenas alerta.
- Define `default_phone_region` (usa `NC_DEFAULT_PHONE_REGION`, padrão BR) e roda `db:add-missing-indices` + `maintenance:repair --include-expensive`.
- Define `trusted_proxies` (usa `NC_TRUSTED_PROXIES` ou padrão `172.17.0.1,127.0.0.1`) e força `overwriteprotocol=https` para evitar aviso de proxy reverso.

### Ajuste de brute force para redes internas (apenas LAN confiável)
- Use somente em ambiente local controlado; não aplique em Nextcloud exposto à internet.
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
- `NEXTCLOUD_IMAGE`: imagem/tag do Nextcloud; padrão `nextcloud:29-apache` (estável). Ajuste para atualizar, mas evite downgrade de dados.
- `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD`: defina para criar o admin automaticamente na primeira inicialização. Se deixar em branco, a UI pedirá usuário/senha na tela de instalação.
- `NC_DB_ROOT_PASSWORD`, `NC_DB_PASSWORD`: senhas do MariaDB.
- Volumes (`/data/...`): paths persistentes no host para Nextcloud e OnlyOffice.
- `NC_OVERWRITE_*`: URLs externas (HTTPS) usadas pelo Nextcloud.
- `NC_TRUSTED_DOMAINS`: domínios permitidos (vírgula para múltiplos).
- `NC_TRUSTED_PROXIES`: IP do host Docker (geralmente `172.17.0.1`) e `127.0.0.1`.
- `NC_TRUSTED_PROXIES` e headers no proxy: as confs Nginx já incluem Forwarded/X-Forwarded-*; mantenha `NC_TRUSTED_PROXIES` com o IP do host/proxy e recarregue o Nginx após copiar as confs.
- `OO_PUBLIC_URL`, `OO_INTERNAL_URL`, `NC_INTERNAL_URL`: URLs externa e internas do Document Server.
- `OO_JWT_SECRET`: segredo longo e aleatório (`openssl rand -hex 32`).
- `NC_DEFAULT_PHONE_REGION`: código de país ISO (ex.: BR) para validar números; usado no pós-install.
- `OPCACHE_MEMORY` / `OPCACHE_INTERNED_STRINGS` / `OPCACHE_MAX_ACCELERATED_FILES`: tunar o OPcache (padrão 512 MB, 16, 100000).
- `NC_DEFAULT_LANGUAGE` / `NC_DEFAULT_LOCALE`: idioma padrão no primeiro login (ex.: `pt_BR`).
- `TZ`: timezone compartilhado pelos serviços.

## OPcache persistente
- O compose monta `overrides/php/opcache.ini` em ambos os contêineres (`nc-app` e `nc-cron`) para manter o OPcache em 1G (`opcache.memory_consumption=1024`, `opcache.max_accelerated_files=200000`, `memory_limit=1G`), mesmo após recriações. Ajuste esse arquivo se quiser outros valores.

## Ajuste do Nginx no host
1. O setup aplica automaticamente as confs do Nginx renderizadas a partir dos templates (`nginx/cloud.mms.conf`, `nginx/onlyoffice.mms.conf`) para `/etc/nginx/sites-available/<domínio>.conf` e habilita em `/etc/nginx/sites-enabled/`.
2. Se usar outros domínios ou caminhos de certificado, ajuste os templates antes de rodar o setup, ou edite os arquivos gerados em `/etc/nginx/sites-available/`.
3. Garanta que o certificado contém os SAN corretos e é assinado pela sua CA interna (ou Let’s Encrypt).
4. Recarregue o Nginx do host: `sudo nginx -t && sudo systemctl reload nginx` (o setup já chama reload; repita se ajustar algo).
5. As confs já incluem redirects de `/.well-known/caldav|carddav` para `/remote.php/dav`, cabeçalhos `X-Content-Type-Options`/`X-Frame-Options`/HSTS e cabeçalho `Forwarded`/`X-Forwarded-*`.

### Cloudflare como proxy reverso (Internet ou LAN com túnel)
- Perfil `cloudflare` no setup:
  - Nginx fica só em HTTP (127.0.0.1:8080/8082); o TLS é terminado pelo Cloudflare/túnel.
  - Não roda certbot nem gera CA interna; nada de prompts de certificado.
  - Aplica automaticamente real IP da Cloudflare via `scripts/cloudflare-realip.sh`.
- Real IP manual (se precisar rodar fora do setup):
  ```bash
  sudo bash scripts/cloudflare-realip.sh
  sudo nginx -t && sudo systemctl reload nginx
  ```
  Cria `/etc/nginx/conf.d/cloudflare-realip.conf` com `set_real_ip_from` e `real_ip_header CF-Connecting-IP`.
- Nextcloud: `trusted_proxies` e `overwriteprotocol=https` são aplicados no pós-install.
- Se usar túnel do Cloudflare em LAN (sem abrir portas), faça manualmente após o setup:
  ```bash
  # instalar cloudflared
  sudo mkdir -p /usr/local/bin
  sudo curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  sudo chmod +x /usr/local/bin/cloudflared
  cloudflared --version

  # login e criação do túnel (etapa interativa abre link/código)
  cloudflared tunnel login
  cloudflared tunnel create nextcloud-tunel   # guarde o Tunnel ID e credencial JSON

  # config do túnel (ajuste domínios/ports)
  cat > ~/.cloudflared/config.yml <<'EOF'
  tunnel: nextcloud-tunel
  credentials-file: /root/.cloudflared/<credencial>.json

  ingress:
    - hostname: cloud.seudominio.com
      service: http://127.0.0.1:8080
    - hostname: onlyoffice.seudominio.com
      service: http://127.0.0.1:8082
    - service: http_status:404
  EOF

  # rodar o túnel (ou instalar como serviço)
  cloudflared tunnel run nextcloud-tunel
  # opcional: cloudflared service install
  ```
  Depois crie CNAMEs na Cloudflare apontando para o domínio do túnel (`xxx.cfargotunnel.com`) com proxy laranja ativo.
- Passo simplificado com token (recomendado para iniciantes): no painel da Cloudflare copie o comando `sudo cloudflared service install <token>` e cole quando o setup (perfil cloudflare) pedir o token. Ele registra o túnel como serviço automaticamente; depois só ajuste o `config.yml` gerado e crie os CNAMEs.

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

## Comandos úteis (occ)
Rode sempre como `www-data` no contêiner: `docker exec -u www-data nc-app php occ <comando>`.
- `status`: mostra versão, modo de manutenção e caminho de dados.
- `trashbin:cleanup --all-users`: limpa lixeira de todos os usuários respeitando a retenção configurada.
- `versions:cleanup`: remove versões antigas de arquivos conforme política de retenção.
- `files:cleanup`: remove entradas órfãs do filecache (após exclusões manuais).
- `files:scan --all` (ou `--path user/files/alguma_pasta`): reindexa arquivos após mover algo fora do Nextcloud; use somente quando necessário.
- `maintenance:repair`: roda reparos comuns (índices, shares, storages inconsistentes).
- `db:add-missing-indices`: cria índices que faltam (executar após upgrades quando o log sugerir).
- `db:convert-filecache-bigint`: converte colunas do filecache para bigint (rodar uma vez; pode ser demorado).
- `app:update --all`: atualiza apps instalados após atualizar o Nextcloud.

## Manutenção e performance
- Scan de arquivos: evite `files:scan --all` (puxa CPU/DB). Prefira escopos menores: `docker exec -u www-data nc-app php occ files:scan --path="usuario/files/Pasta"` ou por usuário: `occ files:scan usuario`. Use fora do horário de pico.
- Brute force: se um IP confiável for bloqueado, limpe com `occ security:bruteforce:reset <ip>` ou, se preciso, `TRUNCATE oc_bruteforce_attempts` no banco (com cautela).
- Logs: monitore o tamanho de `data/nextcloud.log`. Ajuste `loglevel` se estiver verboso: `occ config:system:set loglevel --value 2` (info) ou 1 (warning).
- Banco: mantenha índices com `db:add-missing-indices` (pós-upgrade) e use o slow query log do MariaDB se notar consultas lentas.
- OPcache: já fixamos 1G via `overrides/php/opcache.ini`; se quiser outro valor, edite o arquivo e `docker compose up -d` para aplicar.
- Cron: reinicie `app/cron` se notar jobs duplicados ou carga alta sem tráfego: `docker restart nc-app nc-cron`.

## Avisos comuns e como resolver rápido
- **AppAPI deploy daemon**: se não usa Ex-Apps, ignore. Caso contrário, instale/ative o app `app_api` e configure um daemon em Configurações > Administração > Aplicativos Externos.
- **Cabeçalhos Forwarded for**: garanta `NC_TRUSTED_PROXIES` e `NC_OVERWRITE_*` corretos no `.env` e recarregue o Nginx do host. Se precisar, adicione no vhost:
  ```
  proxy_set_header Forwarded "for=$proxy_add_x_forwarded_for;host=$host;proto=$scheme";
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header X-Forwarded-Host $host;
  proxy_set_header X-Forwarded-For  $proxy_add_x_forwarded_for;
  ```
- **Back-end de alto desempenho (Talk)**: sem HPB/TURN o Talk limita a 2–3 usuários. Suba signaling + TURN e configure (`talk:signaling:...` e `talk:turn:add`). Se não usar Talk com grupos, ignore.
- **Janela de manutenção**: defina um horário de baixo uso:
  `docker exec -u www-data nc-app php occ config:system:set maintenance_window_start --value=1` (1=01:00).
- **Migrações de mimetype**: `docker exec -u www-data nc-app php occ maintenance:repair --include-expensive`.
- **Client Push**: instale/ative: `bash scripts/install-apps-base.sh` (já inclui `client_push`).
