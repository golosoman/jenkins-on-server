# Jenkins on Server (Docker + Nginx + Let's Encrypt)

Автоматический разворот Jenkins LTS в Docker с обратным прокси через
Nginx и TLS-сертификатом Let's Encrypt (Certbot).

---

## Минимальные требования

- Домен (например `ci.example.com`) указывает A-записью на IP сервера
- Открыты порты 80 и 443
- Ubuntu 20.04 / 22.04 / 24.04
- Доступ по SSH с sudo

Открыть порты:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

Проверка с локального ПК (Windows PowerShell):

```powershell
Test-NetConnection <IP_ИЛИ_ДОМЕН> -Port 80
Test-NetConnection <IP_ИЛИ_ДОМЕН> -Port 443
```

---

## Структура репозитория

    jenkins-on-server/
    │
    ├── bootstrap.sh
    ├── docker-compose.yml
    ├── nginx/
    │   └── jenkins-http.conf.template
    └── README.md

---

## docker-compose.yml

```yaml
services:
    jenkins:
        build: ./jenkins-image
        container_name: jenkins
        restart: unless-stopped
        user: "0:0"
        # Web публикуется на host ТОЛЬКО на loopback: 127.0.0.1:18080 -> 8080.
        # Порт 50000 (inbound agents) не публикуется — в проекте не используется.
        ports:
            - "127.0.0.1:18080:8080"
        mem_limit: 768m
        environment:
            # Только JENKINS_JAVA_OPTS — его читает entrypoint образа jenkins/jenkins.
            # JAVA_OPTS не задаём: его могут подхватывать другие JVM-инструменты
            # в сборках. mem_limit выше — жёсткий потолок памяти.
            - JENKINS_JAVA_OPTS=-Xms256m -Xmx512m -Djenkins.install.runSetupWizard=true
        volumes:
            - jenkins_home:/var/jenkins_home
            - /var/run/docker.sock:/var/run/docker.sock

volumes:
    jenkins_home:
```

Web Jenkins публикуется на host как `127.0.0.1:18080` (только loopback) и
наружу напрямую не открыт; порт `8080` остаётся внутренним портом контейнера.
`18080` **не предназначен для публичного доступа** — внешний доступ идёт через
reverse proxy. Порт `50000` (inbound agents) не публикуется, т.к. не используется;
если он понадобится, публиковать его нужно только локально как
`127.0.0.1:15000:50000`.
Папка `jenkins-image/` нужна для сборки кастомного образа Jenkins с Docker CLI и Compose plugin.

---

## Nginx (HTTP шаблон)

```nginx
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:18080;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

`X-Forwarded-Proto` обязателен при работе через HTTPS-прокси.

---

## Запуск

```bash
sudo apt-get update -y
sudo apt-get install -y git
git clone https://github.com/<you>/jenkins-on-server.git
cd jenkins-on-server
sudo bash bootstrap.sh -d ci.example.com -e admin@example.com
```

После выполнения:

- Jenkins будет доступен по https://ci.example.com
- В консоли будет выведен initialAdminPassword

---

## Возможная ошибка Docker

Ошибка:

    failed to load listeners: no sockets found via socket activation

Фикс:

```bash
sudo systemctl enable --now docker.socket
sudo systemctl restart docker.socket
sudo systemctl reset-failed docker.service
```

Проверка:

```bash
docker version
docker info
```

---

## Что нужно сделать вручную

- Пройти Initial Setup Wizard Jenkins
- Указать Jenkins URL: Manage Jenkins → System → Jenkins Location

---

## Безопасность

- Web Jenkins публикуется на host только на loopback `127.0.0.1:18080`
  (наружу `0.0.0.0` не биндится); `8080` — внутренний порт контейнера
- Порт `18080` не для публичного доступа — внешний доступ только через reverse proxy
- Порт `50000` (inbound agents) не публикуется (не используется); при необходимости
  — только локально `127.0.0.1:15000:50000`
- Доступ только через HTTPS
- JVM controller ограничена (`-Xms256m -Xmx512m`), память контейнера — `mem_limit: 768m`
- Для слабых серверов: не запускать тяжёлые и параллельные сборки
- Минимальная конфигурация без лишних плагинов

## Пару полезных команд

- docker stop $(docker ps -aq)
- docker rm $(docker ps -aq)
- docker rmi -f $(docker images -aq)
sudo mkdir -p /opt/apps
sudo chown -R root:root /opt/apps
sudo git clone https://github.com/golosoman/ssau-schedule-bot /opt/apps/ssau-schedule-bot
