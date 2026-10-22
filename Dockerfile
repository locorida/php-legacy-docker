# syntax=docker/dockerfile:1.7
#
# php-legacy-docker — one image that replaces a classic "LEMP in a VM" development box:
# nginx, PHP-FPM, MariaDB, Redis, memcached, beanstalkd and Mailpit, all run by supervisord.
#
# Switch the PHP version without touching this file:
#   docker build --build-arg PHP_IMAGE=php:8.4-fpm-trixie -t php-legacy:local .
ARG PHP_IMAGE=php:8.5-fpm-trixie
ARG MAILPIT_IMAGE=axllent/mailpit:v1.31.6
ARG COMPOSER_IMAGE=composer:2

FROM ${MAILPIT_IMAGE} AS mailpit
FROM ${COMPOSER_IMAGE} AS composer

FROM ${PHP_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    DOCUMENT_ROOT=/var/www/html/public \
    DB_NAME=app \
    DB_USER=app \
    DB_PASSWORD=app \
    DB_BUFFER_POOL=256M \
    DB_SQL_MODE=NO_ENGINE_SUBSTITUTION \
    XDEBUG_MODE=off \
    OPCACHE_VALIDATE_TIMESTAMPS=1 \
    WORKER_COMMAND=""

# --- PHP extensions ---------------------------------------------------------------------------
# install-php-extensions resolves build dependencies and removes them again afterwards.
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/download/2.12.3/install-php-extensions /usr/local/bin/

RUN install-php-extensions \
      bcmath calendar exif gd gettext intl mysqli pcntl pdo_mysql soap sockets zip \
      igbinary redis opcache xdebug

# The memcached extension is built from its GitHub tag: PECL releases lag behind new PHP versions.
RUN install-php-extensions php-memcached-dev/php-memcached@v3.4.0

# The official image ships without a php.ini. Classic distro setups start from the production
# template, so legacy code sees the same output_buffering and error_reporting defaults.
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

# --- Services from the Debian repositories ----------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nginx mariadb-server mariadb-client redis-server memcached beanstalkd \
      supervisor ca-certificates curl openssl gettext-base tzdata \
 && rm -rf /var/lib/apt/lists/* \
 # The package creates a database inside the image; the real one lives in a volume.
 && rm -rf /var/lib/mysql/* \
 && rm -f /etc/nginx/sites-enabled/default

COPY --from=mailpit /mailpit /usr/local/bin/mailpit
COPY --from=composer /usr/bin/composer /usr/local/bin/composer

# --- Configuration and start scripts ----------------------------------------------------------
COPY rootfs/ /
COPY app/ /var/www/html/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
 # MariaDB ignores world-writable config files, so the config is baked in with fixed permissions.
 && chmod 0644 /etc/mysql/mariadb.conf.d/zz-app.cnf \
 && mkdir -p /run/mysqld /var/lib/redis /docker-entrypoint-initdb.d /certs \
 && chown mysql:mysql /run/mysqld \
 && chown redis:redis /var/lib/redis

WORKDIR /var/www/html
EXPOSE 80 443 3306 1025 8025
STOPSIGNAL SIGTERM
# --start-interval: probe every second while starting, so "healthy" is reported without delay.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --start-interval=1s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
