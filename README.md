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
        image: jenkins/jenkins:lts
        container_name: jenkins
        restart: unless-stopped
        user: "0:0"
        ports:
            - "127.0.0.1:8080:8080"
            - "127.0.0.1:50000:50000"
        volumes:
            - jenkins_home:/var/jenkins_home

volumes:
    jenkins_home:
```

Jenkins слушает только localhost --- наружу порт 8080 не открыт.

---

## Nginx (HTTP шаблон)

```nginx
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

- Порт 8080 не открыт наружу
- Доступ только через HTTPS
- Минимальная конфигурация без лишних плагинов
