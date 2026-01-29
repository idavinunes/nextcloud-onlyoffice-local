ARG BASE_IMAGE=nextcloud:30-apache
FROM ${BASE_IMAGE}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      smbclient libsmbclient-php \
      php-ssh2 openssh-client && \
    rm -rf /var/lib/apt/lists/*
