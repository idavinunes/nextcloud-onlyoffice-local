ARG BASE_IMAGE=nextcloud:30-apache
FROM ${BASE_IMAGE}

# SMB/SFTP support via pecl (bookworm não traz php-smbclient/php-ssh2 prontos)
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      smbclient \
      libsmbclient-dev libssh2-1-dev libkrb5-dev \
      php-dev php-pear pkg-config gcc g++ make \
      openssh-client; \
    printf "\n" | pecl install smbclient; \
    pecl install ssh2-1.4; \
    docker-php-ext-enable smbclient ssh2; \
    rm -rf /var/lib/apt/lists/*
