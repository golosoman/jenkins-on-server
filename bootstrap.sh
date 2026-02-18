#!/usr/bin/env bash
set -euo pipefail

# Быстрый разворот Jenkins + Nginx + Let's Encrypt на Ubuntu
# Usage:
#   sudo ./bootstrap.sh -d ci.example.com -e admin@example.com

DOMAIN=""
EMAIL=""
APP_DIR="/opt/jenkins"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: sudo $0 -d <domain> -e <email>"
  exit 1
}

while getopts "d:e:" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    e) EMAIL="$OPTARG" ;;
    *) usage ;;
  esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  usage
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0 -d $DOMAIN -e $EMAIL"
  exit 1
fi

echo "[1/8] apt update + базовые пакеты"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

echo "[2/8] Установка Docker Engine (официальный репозиторий Docker)"
# По официальной схеме установки Docker на Ubuntu: ключ + repo + docker-ce :contentReference[oaicite:6]{index=6}
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  ${UBUNTU_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

echo "[3/8] Установка Nginx"
apt-get install -y nginx
systemctl enable --now nginx

echo "[4/8] Разворачиваем Jenkins (docker compose) в ${APP_DIR}"
mkdir -p "${APP_DIR}"
cp -f "${REPO_DIR}/docker-compose.yml" "${APP_DIR}/docker-compose.yml"
cd "${APP_DIR}"
docker compose up -d

echo "[5/8] Настраиваем Nginx site для Jenkins (HTTP)"
NGINX_AVAIL="/etc/nginx/sites-available/jenkins.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/jenkins.conf"

# рендерим шаблон
sed "s/\${DOMAIN}/${DOMAIN}/g" "${REPO_DIR}/nginx/jenkins-http.conf.template" > "${NGINX_AVAIL}"

ln -sf "${NGINX_AVAIL}" "${NGINX_ENABLED}"

# отключаем default site если включён
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl reload nginx

echo "[6/8] Установка Certbot (snap) + выпуск TLS сертификата"
# Certbot рекомендует snap как стандартный путь; команда certbot --nginx — “в один шаг”. :contentReference[oaicite:7]{index=7}
apt-get install -y snapd
snap install core || true
snap refresh core || true
snap install certbot --classic
ln -sf /snap/bin/certbot /usr/bin/certbot

# Важно: порт 80 должен быть доступен снаружи, иначе валидация не пройдёт.
certbot --nginx \
  -d "${DOMAIN}" \
  --non-interactive \
  --agree-tos \
  -m "${EMAIL}" \
  --redirect

echo "[7/8] Финальные настройки: Jenkins URL под прокси"
# Автоматом через UI проще, но можно хотя бы подсказать где:
echo "Jenkins будет доступен по: https://${DOMAIN}"
echo "В Jenkins: Manage Jenkins -> System -> Jenkins Location -> Jenkins URL = https://${DOMAIN}/"

echo "[8/8] Выводим initialAdminPassword"
docker exec -it jenkins cat /var/jenkins_home/secrets/initialAdminPassword || true

echo "DONE."
