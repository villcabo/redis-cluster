#!/usr/bin/env bash
# Certificado self-signed para HTTPS de oauth2-proxy (modo insight-oauth).
# Genera ./certs/oauth2-proxy.{crt,key}. CN = ANNOUNCE_IP del .env.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v openssl >/dev/null || { echo "ERROR: instalá openssl"; exit 1; }

CN="127.0.0.1"
if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
  CN="${ANNOUNCE_IP:-127.0.0.1}"
fi

mkdir -p certs && chmod 700 certs
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -keyout certs/oauth2-proxy.key -out certs/oauth2-proxy.crt \
  -subj "/C=BO/ST=Santa Cruz/L=Santa Cruz/O=Sintesis S.A./OU=IT/CN=${CN}"

echo "Certificado generado en ./certs (CN=${CN})"
