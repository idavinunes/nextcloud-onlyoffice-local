# Rclone + Dropbox (montar subpasta e expor para o Nextcloud em Docker)

Passo-a-passo resumido para usar uma pasta do Dropbox como armazenamento externo (Local) no Nextcloud rodando em Docker.

## 0) Pré-requisitos
- Ubuntu/Debian no host do Docker
- rclone configurado com o remoto `dropbox` (\`rclone config\`)
- Espaço em disco local para cache/staging

## 1) Instalar rclone e fuse3
```bash
sudo apt-get update
sudo apt-get install -y rclone fuse3
```

## 2) Escolher a subpasta a montar
Exemplo: montar somente `/davi/advec` do Dropbox.

## 3) Criar ponto de montagem no host (use o disco com espaço, ex.: /data)
```bash
sudo mkdir -p /data/dropbox-advec
sudo chown davi:davi /data/dropbox-advec   # ajuste o usuário conforme o ambiente
```

## 4) Service systemd para montar no boot
Crie `/etc/systemd/system/rclone-dropbox-advec.service`:

```ini
[Unit]
Description=Rclone mount Dropbox (pasta davi/advec)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=davi                          # ajuste o usuário ou use root se preferir
ExecStart=/usr/bin/rclone mount dropbox:/davi/advec /data/dropbox-advec \
  --vfs-cache-mode=full \
  --vfs-cache-max-size 20G \
  --vfs-cache-max-age 168h \
  --dir-cache-time 12h \
  --poll-interval 5m \
  --allow-other \
  --umask 002 \
  --log-file=/var/log/rclone-dropbox.log \
  --log-level INFO
ExecStop=/bin/fusermount -u /data/dropbox-advec
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

> Se der erro de permissão no log, crie o arquivo e dê permissão ao user do serviço:
> `sudo touch /var/log/rclone-dropbox.log && sudo chown davi:davi /var/log/rclone-dropbox.log`

Aplicar:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rclone-dropbox-advec.service
sudo systemctl status rclone-dropbox-advec.service --no-pager
```

Verificar o mount:
```bash
mount | grep dropbox-advec
ls /data/dropbox-advec | head
```

### Cache mais “rápido” (opcional)
Se quiser ver novas pastas do Dropbox em poucos minutos, reduza:
- `--dir-cache-time 5m`
- `--poll-interval 1m`

Reinicie o serviço após ajustes:
```bash
sudo systemctl restart rclone-dropbox-advec.service
```

## 5) Expor o mount para o Nextcloud em Docker
No `docker-compose.yml`, acrescente o bind nos serviços `app` e `cron` (opção já comentada no arquivo):

```yaml
  app:
    volumes:
      ...
      - /data/dropbox-advec:/data/dropbox-advec:rw

  cron:
    volumes:
      ...
      - /data/dropbox-advec:/data/dropbox-advec:rw
```

Aplicar:
```bash
docker compose up -d app cron
```

## 6) Configurar no Nextcloud
- Ative o app “Armazenamento externo”.
- Configurações → Armazenamento externo → Tipo **Local**.
- Caminho: `/data/dropbox-advec` (o caminho visto dentro do contêiner).
- Selecione usuários/grupos e salve.

## Notas
- O rclone baixa arquivos só quando acessados (on-demand). O cache é limitado por `--vfs-cache-max-size`.
- Uploads grandes via mount precisam de espaço livre no cache durante o envio; para muito grandes, considere `rclone copy` direto em vez de via mount.
- Para forçar refresh de listagem quando subir arquivos direto pelo Dropbox, reinicie o serviço ou reduza `--dir-cache-time` + `--poll-interval`.
