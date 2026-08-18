#!/bin/sh
# Same checks as Terminal-Bench 2.1 nginx-request-logging/tests/test_outputs.py
set -eu
fail() { printf '%s\n' "$1" >&2; exit 1; }

command -v nginx >/dev/null 2>&1 || fail 'nginx not installed'
nginx -t >/dev/null 2>&1 || fail 'nginx -t failed'

idx=$(curl -sS -o /tmp/ng-idx --connect-timeout 5 --max-time 8 \
  -w '%{http_code}' http://127.0.0.1:8080/ || true)
[ "$idx" = 200 ] || fail "index status $idx"
grep -qx 'Welcome to the benchmark webserver' /tmp/ng-idx \
  || fail 'index body mismatch'

nf=$(curl -sS -o /tmp/ng-404 --connect-timeout 5 --max-time 8 \
  -w '%{http_code}' http://127.0.0.1:8080/nonexistent-page || true)
[ "$nf" = 404 ] || fail "404 status $nf"
grep -qx 'Page not found - Please check your URL' /tmp/ng-404 \
  || fail '404 body mismatch'

[ -f /etc/nginx/conf.d/benchmark-site.conf ] || fail 'missing benchmark-site.conf'
site=$(cat /etc/nginx/conf.d/benchmark-site.conf)
printf '%s' "$site" | grep -Eq 'listen[[:space:]]+8080' || fail 'listen 8080 missing'
printf '%s' "$site" | grep -Eq 'root[[:space:]]+/var/www/html' || fail 'root missing'

[ -f /etc/nginx/nginx.conf ] || fail 'missing nginx.conf'
main=$(cat /etc/nginx/nginx.conf)
printf '%s' "$main" | grep -q 'log_format' || fail 'no log_format'
for f in '$time_local' '$request_method' '$status' '$http_user_agent'; do
  printf '%s' "$main" | grep -F -q "$f" || fail "log format missing $f"
done
printf '%s' "$main" | grep -Eq 'limit_req_zone.*rate=10r/s' \
  || fail 'limit_req_zone 10r/s missing'

curl -sS -o /dev/null http://127.0.0.1:8080/ || true
sleep 1
[ -f /var/log/nginx/benchmark-access.log ] || fail 'access log missing'
uniq=/test-slab-$$
curl -sS -o /dev/null -A 'slab-bench-agent' "http://127.0.0.1:8080$uniq" || true
sleep 1
log=$(cat /var/log/nginx/benchmark-access.log)
printf '%s' "$log" | grep -Eq '[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}' \
  || fail 'log timestamp missing'
printf '%s' "$log" | grep -Eq 'GET|POST|HEAD' || fail 'log method missing'
printf '%s' "$log" | grep -Eq '[[:space:]][0-9]{3}[[:space:]]' || fail 'log status missing'
printf '%s' "$log" | grep -q '"' || fail 'log user-agent quotes missing'

printf 'pass\n'
