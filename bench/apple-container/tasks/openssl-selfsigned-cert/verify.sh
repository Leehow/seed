#!/bin/sh
# Same checks as Terminal-Bench 2.1 openssl-selfsigned-cert/tests/test_outputs.py
set -eu
fail() { printf '%s\n' "$1" >&2; exit 1; }

[ -d /app/ssl ] || fail 'missing /app/ssl'
[ -f /app/ssl/server.key ] || fail 'missing server.key'
perm=$(stat -c '%a' /app/ssl/server.key)
case $perm in
  600|400) ;;
  *) fail "key permissions too open: $perm" ;;
esac
openssl rsa -in /app/ssl/server.key -text -noout 2>/dev/null | grep -q '2048 bit' \
  || fail 'key is not 2048-bit RSA'

[ -f /app/ssl/server.crt ] || fail 'missing server.crt'
ct=$(openssl x509 -in /app/ssl/server.crt -text -noout)
printf '%s' "$ct" | grep -q 'dev-internal.company.local' || fail 'CN missing'
printf '%s' "$ct" | grep -qi 'devops team' || fail 'O missing'

nb=$(openssl x509 -in /app/ssl/server.crt -noout -startdate | sed 's/notBefore=//')
na=$(openssl x509 -in /app/ssl/server.crt -noout -enddate | sed 's/notAfter=//')
sb=$(date -d "$nb" +%s)
sa=$(date -d "$na" +%s)
days=$(( (sa - sb) / 86400 ))
[ "$days" -eq 365 ] || fail "validity is $days days, expected 365"

[ -f /app/ssl/server.pem ] || fail 'missing server.pem'
grep -q 'PRIVATE KEY' /app/ssl/server.pem || fail 'pem missing key'
grep -q 'CERTIFICATE' /app/ssl/server.pem || fail 'pem missing cert'
openssl x509 -in /app/ssl/server.pem -text -noout >/dev/null \
  || fail 'pem certificate unreadable'

[ -f /app/ssl/verification.txt ] || fail 'missing verification.txt'
vf=$(cat /app/ssl/verification.txt)
printf '%s' "$vf" | grep -qi 'dev-internal.company.local' || fail 'verification missing CN'
printf '%s' "$vf" | grep -qi 'devops team' || fail 'verification missing O'
printf '%s' "$vf" | grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}|[A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+[0-9]{4}' \
  || fail 'verification missing dates'
printf '%s' "$vf" | tr 'A-F' 'a-f' | grep -Eq '[0-9a-f]{2}(:[0-9a-f]{2}){31}' \
  || fail 'verification missing SHA-256 fingerprint'

[ -f /app/check_cert.py ] || fail 'missing check_cert.py'
py=python3
command -v python >/dev/null 2>&1 && py=python
out=$($py /app/check_cert.py) || fail 'check_cert.py failed'
printf '%s' "$out" | grep -q 'Certificate verification successful' \
  || fail 'check_cert.py missing success line'
printf '%s' "$out" | grep -q 'dev-internal.company.local' \
  || fail 'check_cert.py missing CN'
printf '%s' "$out" | grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
  || fail 'check_cert.py missing YYYY-MM-DD'

printf 'pass\n'
