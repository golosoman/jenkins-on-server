#!/usr/bin/env bash
set -euo pipefail

# Устанавливает nginx site для ssau-schedule frontend на уже подготовленном сервере.
# Jenkins остаётся отдельным site на своём домене/порту.

DOMAIN=""
EMAIL=""
HTTPS_PORT="8444"
FRONTEND_ROOT="/opt/apps/ssau-schedule-frontend/current"
API_UPSTREAM="http://127.0.0.1:3100"
SKIP_CERTBOT="false"
CERT_DOMAIN=""
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./install-ssau-frontend-site.sh -d <frontend-domain> [-e <email>] [-p <https-port>] [-r <frontend-root>] [-u <api-upstream>] [-n]
  sudo ./install-ssau-frontend-site.sh -d <domain> -c <cert-domain> [-p <https-port>] [-r <frontend-root>] [-u <api-upstream>]

Options:
  -d  Frontend domain, например app.example.com
  -e  Email для Let's Encrypt. Если не задан, certbot не запускается
  -p  HTTPS port для certbot --https-port. Default: 8444
  -r  Каталог со статикой фронта. Default: /opt/apps/ssau-schedule-frontend/current
  -u  Backend API upstream. Default: http://127.0.0.1:3100
  -c  Переиспользовать существующий certbot-сертификат и поставить HTTPS-only site.
      Нужно, если frontend на том же domain, что Jenkins, но на другом порту
  -n  Не запускать certbot, только поставить HTTP nginx site
USAGE
  exit 1
}

while getopts "d:e:p:r:u:c:n" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    e) EMAIL="$OPTARG" ;;
    p) HTTPS_PORT="$OPTARG" ;;
    r) FRONTEND_ROOT="$OPTARG" ;;
    u) API_UPSTREAM="$OPTARG" ;;
    c) CERT_DOMAIN="$OPTARG" ;;
    n) SKIP_CERTBOT="true" ;;
    *) usage ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  usage
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0 -d ${DOMAIN}"
  exit 1
fi

API_UPSTREAM="${API_UPSTREAM%/}"

if ! command -v nginx >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y nginx
fi

systemctl enable --now nginx

mkdir -p "${FRONTEND_ROOT}"

NGINX_AVAIL="/etc/nginx/sites-available/ssau-frontend.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/ssau-frontend.conf"

if [[ -n "${CERT_DOMAIN}" ]]; then
  CERT_DIR="/etc/letsencrypt/live/${CERT_DOMAIN}"
  if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
    echo "Certbot certificate not found in ${CERT_DIR}"
    echo "Run certbot for ${CERT_DOMAIN} first, or omit -c to create a new frontend certificate."
    exit 1
  fi

  TEMPLATE="${REPO_DIR}/nginx/ssau-frontend-https-port.conf.template"
  sed \
    -e "s|\${FRONTEND_DOMAIN}|${DOMAIN}|g" \
    -e "s|\${FRONTEND_HTTPS_PORT}|${HTTPS_PORT}|g" \
    -e "s|\${FRONTEND_ROOT}|${FRONTEND_ROOT}|g" \
    -e "s|\${API_UPSTREAM}|${API_UPSTREAM}|g" \
    -e "s|\${CERT_DOMAIN}|${CERT_DOMAIN}|g" \
    "${TEMPLATE}" > "${NGINX_AVAIL}"
else
  TEMPLATE="${REPO_DIR}/nginx/ssau-frontend-http.conf.template"
  sed \
    -e "s|\${FRONTEND_DOMAIN}|${DOMAIN}|g" \
    -e "s|\${FRONTEND_ROOT}|${FRONTEND_ROOT}|g" \
    -e "s|\${API_UPSTREAM}|${API_UPSTREAM}|g" \
    "${TEMPLATE}" > "${NGINX_AVAIL}"
fi

ln -sf "${NGINX_AVAIL}" "${NGINX_ENABLED}"

nginx -t
systemctl reload nginx

if [[ -n "${CERT_DOMAIN}" ]]; then
  echo "HTTPS frontend site is ready: https://${DOMAIN}:${HTTPS_PORT}"
  exit 0
fi

if [[ "${SKIP_CERTBOT}" == "true" || -z "${EMAIL}" ]]; then
  echo "HTTP site installed for ${DOMAIN}."
  echo "To enable TLS later:"
  echo "  sudo certbot --nginx -d ${DOMAIN} --https-port ${HTTPS_PORT} --redirect"
  exit 0
fi

if ! command -v certbot >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y snapd
  snap install core || true
  snap refresh core || true
  snap install certbot --classic
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi

certbot --nginx \
  -d "${DOMAIN}" \
  --non-interactive \
  --agree-tos \
  -m "${EMAIL}" \
  --https-port "${HTTPS_PORT}" \
  --redirect

echo "Frontend nginx site is ready: https://${DOMAIN}:${HTTPS_PORT}"
