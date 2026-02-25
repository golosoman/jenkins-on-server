# JenkinsReadme.md

## 1) Что уже развернуто

- Jenkins запущен в Docker и слушает локально `127.0.0.1:8080`
- Nginx работает как reverse-proxy и публикует Jenkins наружу по HTTPS
- Сертификат Let’s Encrypt выпущен и настроено автопродление

Если Jenkins доступен по `https://<DOMAIN>` — базовая часть готова.

---

## 2) Первичная настройка Jenkins (обязательно сделать 1 раз)

1) Открой Jenkins в браузере: `https://<DOMAIN>`
2) Вставь **initialAdminPassword** (скрипт выводил его в конце; также можно получить так):
   ```bash
   docker exec -it jenkins cat /var/jenkins_home/secrets/initialAdminPassword
   ```
3) Нажми **Install suggested plugins**
4) Создай admin-пользователя
5) Проверь базовую настройку URL:
   - `Manage Jenkins → System → Jenkins Location → Jenkins URL`
   - Должно быть: `https://<DOMAIN>/`

> Важно: при работе за reverse-proxy Jenkins чувствителен к корректным заголовкам. Для HTTPS→HTTP проксирования нужно, чтобы прокси передавал `X-Forwarded-Proto`.

---

## 3) Настройка GitHub Credentials (для Multibranch)

### Почему “Secret text” не подходит
Для **GitHub Branch Source** (Multibranch) Jenkins показывает только credential типа **“Username with password”**.

### Как создать правильный credential
1) `Manage Jenkins → Credentials → (global) → Add Credentials`
2) `Kind`: **Username with password**
3) `Username`: ваш GitHub username
4) `Password`: **GitHub Personal Access Token (PAT)**
5) `ID`: например `github-pat`
6) `Scope`: Global

---

## 4) Multibranch Pipeline: создание и настройка (подробно)

### 4.1 Создать job
1) `Dashboard → New Item`
2) Имя: например `my-project`
3) Тип: **Multibranch Pipeline**
4) `OK`

### 4.2 Branch Sources → GitHub
1) Открой job → `Configure`
2) В блоке **Branch Sources** нажми `Add source → GitHub`
3) `Credentials`: выбери `github-pat`
4) Укажи репозиторий:
   - либо `Owner/Repo`
   - либо через поля/URL (зависит от UI)

### 4.3 Где должен лежать Jenkinsfile
По умолчанию Multibranch ищет файл **`Jenkinsfile`** в корне репозитория (Script Path = `Jenkinsfile`).

Минимальный `Jenkinsfile` для проверки:

```groovy
pipeline {
  agent any
  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Test')     { steps { sh 'echo OK' } }
  }
}
```

### 4.4 Первый запуск
После сохранения:
- Открой Multibranch job
- Нажми **“Scan Multibranch Pipeline Now”**

Ожидаемо: Jenkins создаст подпроекты по веткам (например `main`) и запустит build.

---

## 5) GitHub Webhook: как добавить правильно (очень подробно)

GitHub webhooks — это механизм, когда GitHub отправляет HTTP POST на ваш сервер при событиях (push, PR и т.п.).

### 5.1 Какой URL указывать для Jenkins

Для Jenkins GitHub интеграции обычно используется endpoint:

```
https://<DOMAIN>/github-webhook/
```

**Важно:** слеш в конце (`/`) лучше оставлять.

### 5.2 Пошагово в интерфейсе GitHub

1) Открой репозиторий на GitHub.
2) Перейди в `Settings`.
3) В левом меню выбери `Webhooks`.
4) Нажми `Add webhook`.
5) Заполни поля:

- **Payload URL**: `https://<DOMAIN>/github-webhook/`
- **Content type**: `application/json`
- **Secret**: задай случайную строку (рекомендуется)
- **Which events would you like to trigger this webhook?**
  - Для старта достаточно: **Just the push event**
  - Далее можно включить PR events, если нужно CI на PR

6) Нажми `Add webhook`.

### 5.3 Как проверить, что webhook реально работает

1) Открой созданный webhook в GitHub.
2) Посмотри **Recent Deliveries**:
   - после создания будет событие **ping**
   - у каждой доставки есть HTTP status и response
   - если там **timeout / could not connect** — GitHub физически не может достучаться до Jenkins (обычно firewall/порт/домен)

---

## 6) Что должно происходить после push

Ожидаемый поток:

1) Ты делаешь `git push` в репозиторий (например в `main`)
2) GitHub отправляет webhook на `https://<DOMAIN>/github-webhook/`
3) Jenkins (Multibranch) получает событие и:
   - либо запускает build сразу
   - либо инициирует rescan веток и затем запускает build

---

## 7) Типовые проблемы и быстрые решения

### 7.1 Webhook в GitHub показывает timeout
Почти всегда:
- домен не указывает на сервер
- закрыт порт 443/80 на уровне провайдера
- reverse-proxy неправильно настроен

### 7.2 Jenkins ругается на reverse proxy (“reverse proxy setup is broken”)
Если снаружи HTTPS, а до Jenkins внутри HTTP, нужно корректно передавать `X-Forwarded-Proto`.

### 7.3 Multibranch не видит ветки / не создаёт job для main
Почти всегда причина одна:
- в ветке нет `Jenkinsfile` по пути Script Path

Сделай `Scan Multibranch Pipeline Now` и смотри **Scan Log**.
