ARG BASE_IMAGE=nextcloud:30-apache-bullseye
FROM ${BASE_IMAGE}

# SMB/SFTP support (bullseye tem pacotes php-smbclient/php-ssh2 prontos)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      smbclient libsmbclient-php php-ssh2 openssh-client && \
    rm -rf /var/lib/apt/lists/*
