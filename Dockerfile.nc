ARG BASE_IMAGE=nextcloud:30-apache
FROM ${BASE_IMAGE}

# SMB/SFTP support via pecl (bookworm não traz pacotes php-smbclient/php-ssh2 prontos)
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      smbclient \
      libsmbclient-dev libssh2-1-dev \
      php-pear php-dev pkg-config gcc make \
      openssh-client; \
    pecl install smbclient ssh2-1.4; \
    docker-php-ext-enable smbclient ssh2; \
    apt-get purge -y php-dev pkg-config gcc make php-pear libsmbclient-dev libssh2-1-dev; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*
