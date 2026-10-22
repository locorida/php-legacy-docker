#!/bin/sh
# Docker HEALTHCHECK: healthy once nginx + PHP-FPM, MariaDB and Redis answer.
set -e
curl -fsS -o /dev/null http://127.0.0.1/fpm-ping
mariadb-admin --socket=/run/mysqld/mysqld.sock ping --silent
redis-cli -h 127.0.0.1 ping | grep -q PONG
