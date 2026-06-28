# CI/CD Deploy

Инфраструктурный репозиторий для сервера: Jenkins в Docker, host-nginx и
nginx-site для фронтенда `ssau-schedule-bot`.

Это правильное место для nginx-конфигов. В репозитории приложения остаются
`Jenkinsfile` и код приложения, а server-level конфиги, certbot и публикация
портов живут здесь.

---

## Минимальные требования

- Домен (например `ci.example.com`) указывает A-записью на IP сервера
- Открыты порты 80 и 8443
- Ubuntu 20.04 / 22.04 / 24.04
- Доступ по SSH с sudo

> Jenkins публикуется по HTTPS на нестандартном порту **8443**, т.к. `443` на
> этом сервере занят другим сайтом. Порт `80` всё равно нужен — по нему идёт
> ACME-проверка Let's Encrypt и редирект HTTP → HTTPS.

Открыть порты:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 8443/tcp
```

Проверка с локального ПК (Windows PowerShell):

```powershell
Test-NetConnection <IP_ИЛИ_ДОМЕН> -Port 80
Test-NetConnection <IP_ИЛИ_ДОМЕН> -Port 8443
```

---

## Структура репозитория

    ci-cd-deploy/
    │
    ├── bootstrap.sh
    ├── docker-compose.yml
    ├── install-ssau-frontend-site.sh
    ├── nginx/
    │   ├── jenkins-http.conf.template
    │   ├── ssau-frontend-https-port.conf.template
    │   └── ssau-frontend-http.conf.template
    ├── jenkins-image/
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

В шаблоне только `listen 80`. HTTPS-блок (`listen 8443 ssl`) и редирект
HTTP → HTTPS добавляет Certbot во время `bootstrap.sh` командой
`certbot --nginx --https-port 8443 --redirect`. Публичный HTTPS вынесен на
**8443**, потому что `443` занят другим сайтом; upstream всегда `http://127.0.0.1:18080`.

`X-Forwarded-Proto` обязателен при работе через HTTPS-прокси.

---

## Запуск

### Jenkins

```bash
sudo apt-get update -y
sudo apt-get install -y git
git clone https://github.com/<you>/ci-cd-deploy.git
cd ci-cd-deploy
sudo bash bootstrap.sh -d ci.example.com -e admin@example.com
```

После выполнения:

- Jenkins будет доступен по https://ci.example.com:8443
- В консоли будет выведен initialAdminPassword

### Frontend site для ssau-schedule-bot

Фронт собирается отдельной Jenkins Pipeline-джобой из
`ssau-schedule-bot/frontend/Jenkinsfile` и публикует `dist` сюда:

```text
/opt/apps/ssau-schedule-frontend/current
```

Host-nginx должен раздавать этот каталог и проксировать `/api` на backend.
Если у фронта отдельный домен/поддомен, можно выпустить отдельный certbot-site:

```bash
sudo bash install-ssau-frontend-site.sh \
  -d app.example.com \
  -e admin@example.com \
  -p 8444
```

По умолчанию:

- HTTPS frontend port: `8444`
- frontend root: `/opt/apps/ssau-schedule-frontend/current`
- API upstream: `http://127.0.0.1:3100`

Если TLS пока не нужен или certbot уже настраивается вручную:

```bash
sudo bash install-ssau-frontend-site.sh -d app.example.com -n
```

После этого frontend будет доступен как:

```text
https://app.example.com:8444
```

Если нужен другой порт, передай его через `-p`. Для Let's Encrypt порт `80`
всё равно должен быть открыт снаружи: HTTP-01 challenge всегда приходит на `80`.

Если frontend должен жить на том же домене, что Jenkins, но на другом HTTPS-порту
(`https://ci.example.com:8444`), не создавай второй HTTP-site с тем же
`server_name`: nginx будет конфликтовать на `listen 80`. В этом случае
переиспользуй уже выпущенный сертификат Jenkins:

```bash
sudo bash install-ssau-frontend-site.sh \
  -d ci.example.com \
  -c ci.example.com \
  -p 8444
```

Этот режим ставит только `listen 8444 ssl` для фронта и не трогает HTTP-редирект
Jenkins на `8443`.

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
- Доступ только через HTTPS (публичный порт `8443`, т.к. `443` занят другим сайтом)
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
