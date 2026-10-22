#!/bin/sh
# Prepares the container on every start, then hands over to supervisord.
set -eu

log() { echo "entrypoint: $*"; }

# --- MariaDB ------------------------------------------------------------------------------------
mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld

case "$DB_NAME" in *[!A-Za-z0-9_]*|'') echo "DB_NAME must match [A-Za-z0-9_]+" >&2; exit 1 ;; esac
case "$DB_USER" in *[!A-Za-z0-9_]*|'') echo "DB_USER must match [A-Za-z0-9_]+" >&2; exit 1 ;; esac

if [ ! -d /var/lib/mysql/mysql ]; then
  log "empty data volume, initialising MariaDB"
  chown mysql:mysql /var/lib/mysql
  mariadb-install-db --user=mysql --datadir=/var/lib/mysql \
    --auth-root-authentication-method=socket --skip-test-db >/dev/null

  mariadbd --user=mysql --skip-networking --socket=/run/mysqld/mysqld.sock &
  pid=$!
  until mariadb-admin --socket=/run/mysqld/mysqld.sock ping --silent 2>/dev/null; do sleep 1; done

  # Single quotes inside the password are doubled for the SQL string literal.
  pass=$(printf '%s' "$DB_PASSWORD" | sed "s/'/''/g")
  mariadb --socket=/run/mysqld/mysqld.sock -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

  # Optional seed data: *.sql and *.sql.gz from /docker-entrypoint-initdb.d, in name order.
  for f in /docker-entrypoint-initdb.d/*; do
    case "$f" in
      *.sql)    log "importing $f"; mariadb --socket=/run/mysqld/mysqld.sock -uroot "$DB_NAME" < "$f" ;;
      *.sql.gz) log "importing $f"; gunzip -c "$f" | mariadb --socket=/run/mysqld/mysqld.sock -uroot "$DB_NAME" ;;
    esac
  done

  mariadb-admin --socket=/run/mysqld/mysqld.sock -uroot shutdown
  wait "$pid" || true
  log "MariaDB ready (database '$DB_NAME', user '$DB_USER')"
fi

# --- TLS ----------------------------------------------------------------------------------------
# Prefer the mkcert certificate mounted at /certs; otherwise fall back to a self-signed one so
# the container also starts in CI or before scripts/setup-certs.ps1 has been run.
if [ -f /certs/cert.pem ] && [ -f /certs/key.pem ]; then
  SSL_CERT=/certs/cert.pem
  SSL_KEY=/certs/key.pem
else
  SSL_CERT=/etc/nginx/selfsigned/cert.pem
  SSL_KEY=/etc/nginx/selfsigned/key.pem
  if [ ! -f "$SSL_CERT" ]; then
    log "no certificate in /certs, generating a self-signed fallback"
    mkdir -p /etc/nginx/selfsigned
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
      -keyout "$SSL_KEY" -out "$SSL_CERT" 2>/dev/null
  fi
fi

# --- nginx --------------------------------------------------------------------------------------
# Only our own variables are substituted; nginx variables such as $uri stay untouched.
export SSL_CERT SSL_KEY DOCUMENT_ROOT
envsubst '${SSL_CERT} ${SSL_KEY} ${DOCUMENT_ROOT}' \
  < /etc/nginx/templates/app.conf.template > /etc/nginx/conf.d/app.conf

# --- Optional background worker -----------------------------------------------------------------
rm -f /etc/supervisor/conf.d/worker.conf
if [ -n "$WORKER_COMMAND" ]; then
  log "registering worker: $WORKER_COMMAND"
  cat > /etc/supervisor/conf.d/worker.conf <<EOF
[program:worker]
command=/bin/sh -c 'until mariadb-admin ping -h 127.0.0.1 --silent 2>/dev/null; do sleep 1; done; exec $WORKER_COMMAND'
directory=/var/www/html
user=www-data
priority=50
autorestart=true
startsecs=0
stopwaitsecs=10
stopasgroup=true
killasgroup=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
