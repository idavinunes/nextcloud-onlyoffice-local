ARG BASE_IMAGE=nextcloud:30-apache
FROM ${BASE_IMAGE}

# bookworm: use php-smbclient and explicit php8.2-ssh2
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      smbclient php-smbclient \
      php8.2-ssh2 openssh-client && \
    rm -rf /var/lib/apt/lists/*
