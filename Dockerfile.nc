ARG BASE_IMAGE=nextcloud:31-apache
FROM ${BASE_IMAGE}

# SMB/SFTP support via pecl (mantemos deps de build para compatibilidade)
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      smbclient \
      libssh2-1-dev libsmbclient-dev libkrb5-dev \
      php-dev php-pear pkg-config gcc g++ make autoconf \
      openssh-client; \
    printf "\n" | pecl install smbclient; \
    pecl install ssh2-1.4; \
    docker-php-ext-enable smbclient ssh2; \
    rm -rf /var/lib/apt/lists/*
