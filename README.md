Опираюсь на официальные инструкции: установка Docker на Ubuntu , Jenkins в Docker , Nginx reverse-proxy для Jenkins и важность X-Forwarded-Proto , Certbot + Nginx (команда certbot --nginx) .

0. Минимальные условия (без этого автоматом не взлетит)

Домен (например ci.example.com) должен указывать A-записью на IP сервера.

Порты снаружи открыты: 80 и 443 (иначе Let’s Encrypt не выдаст сертификат).

```На сервере
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

```У себя на пк-проверка
Test-NetConnection <IP_ИЛИ_ДОМЕН> -Port 80
Test-NetConnection <IP_ИЛИ_ДОМЕН> -Port 443
```

Сервер — Ubuntu 20.04+/22.04+/24.04 (скрипт под apt).

Вход по SSH под пользователем с sudo.

1. Как будет выглядеть репозиторий в GitHub
   jenkins-on-server/
   bootstrap.sh
   docker-compose.yml
   nginx/
   jenkins-http.conf.template
   README.md

Ты просто клонируешь репо на сервер и запускаешь bootstrap.sh.

2. docker-compose.yml (Jenkins LTS, слушает только localhost)
   services:
   jenkins:
   image: jenkins/jenkins:lts
   container_name: jenkins
   restart: unless-stopped
   user: "0:0"
   ports: - "127.0.0.1:8080:8080" - "127.0.0.1:50000:50000"
   volumes: - jenkins_home:/var/jenkins_home

volumes:
jenkins_home:

Jenkins официально поддерживает установку/запуск в Docker через jenkins/jenkins (LTS).

3. nginx/jenkins-http.conf.template (HTTP, чтобы certbot смог “подцепиться”)
   server {
   listen 80;
   server_name ${DOMAIN};

location / {
proxy_pass http://127.0.0.1:8080;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

}
}

X-Forwarded-Proto критичен, если внешний доступ по HTTPS, а до Jenkins проксируешь HTTP — Jenkins сам это выделяет как частую причину проблем.

4. bootstrap.sh — основной “автомат”

Скопируй это в bootstrap.sh (и не забудь chmod +x bootstrap.sh в репо).

#!/usr/bin/env bash
set -euo pipefail

# Быстрый разворот Jenkins + Nginx + Let's Encrypt на Ubuntu

# Usage:

# sudo ./bootstrap.sh -d ci.example.com -e admin@example.com

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
\*) usage ;;
esac
done

if [[-z "$DOMAIN" || -z "$EMAIL"]]; then
usage
fi

if [["$(id -u)" -ne 0]]; then
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

if [[-e /etc/nginx/sites-enabled/default]]; then
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

5. Минимальные действия на сервере (твой “runbook”)

В DNS сделай A ci.example.com -> <IP сервера>

Зайди на сервер и выполни:

sudo apt-get update -y
sudo apt-get install -y git
git clone https://github.com/<you>/jenkins-on-server.git
cd jenkins-on-server
sudo bash bootstrap.sh -d ci.example.com -e admin@example.com

После этого:

Jenkins откроется на https://ci.example.com

Скрипт выведет initialAdminPassword

6. Что останется “вручную” (минимум и честно)

Полностью без ручных шагов нельзя, потому что:

Jenkins при первом запуске требует пройти Initial Setup Wizard (админ, плагины).

Нужно будет в Jenkins поставить Jenkins URL (я скриптом подсказал где).

Дальше подключение GitHub webhook и pipeline — уже в Jenkins UI (или через Job DSL/Configuration as Code, но это следующий уровень).

7. Важный нюанс безопасности (коротко)

Так как сервер “голый консольный”, я намеренно:

не открываю Jenkins порт 8080 наружу (только 127.0.0.1) — доступ только через Nginx+TLS.

не добавляю “лишние” плагины/учётки.
