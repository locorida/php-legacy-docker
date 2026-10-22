#!/usr/bin/env bash
# Smoke test against a running container. Used by CI; also runs locally in Git Bash:
#   bash tests/smoke.sh [container] [http-port] [https-port] [expected-php-version-prefix]
set -euo pipefail

container="${1:-php-legacy}"
http_port="${2:-8080}"
https_port="${3:-8443}"
expect_php="${4:-8.5}"

# Git Bash would rewrite container paths such as /var/www to C:/Program Files/Git/var/www.
export MSYS_NO_PATHCONV=1

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

echo "Waiting for $container to become healthy ..."
for _ in $(seq 1 90); do
  status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)
  [[ "$status" == healthy ]] && break
  [[ "$status" == missing ]] && fail "container $container does not exist"
  sleep 2
done
[[ "$status" == healthy ]] || fail "container is '$status' after 180 s"
pass "container healthy"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$http_port/")
[[ "$code" == 200 ]] || fail "HTTP returned $code"
pass "HTTP 200"

code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$https_port/")
[[ "$code" == 200 ]] || fail "HTTPS returned $code"
pass "HTTPS 200"

php_version=$(docker exec "$container" php -r 'echo PHP_VERSION;')
[[ "$php_version" == "$expect_php"* ]] || fail "PHP $php_version, expected $expect_php.x"
pass "PHP $php_version"

docker exec "$container" sh -c 'mariadb -h 127.0.0.1 -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT 1"' >/dev/null \
  || fail "database not reachable over TCP with the app user"
pass "MariaDB reachable as app user"

json=$(curl -s "http://127.0.0.1:$http_port/?format=json")
echo "$json" | grep -q '"ok": true' || { echo "$json"; fail "status page reports failing services"; }
pass "status page: all services OK"

docker exec "$container" php -r 'mail("smoke@example.test", "smoke test", "hello") or exit(1);' \
  || fail "mail() returned false"
for _ in $(seq 1 10); do
  total=$(docker exec "$container" curl -s http://127.0.0.1:8025/api/v1/messages | grep -o '"total":[0-9]*' | cut -d: -f2)
  [[ "${total:-0}" -ge 1 ]] && break
  sleep 1
done
[[ "${total:-0}" -ge 1 ]] || fail "mail did not arrive in Mailpit"
pass "mail() delivered to Mailpit"

echo "All smoke tests passed."
