# Подключение 2btask (учёт задач) вместо Plane

`2btask` (репозиторий `yunisv/2btask`, бывший `bitrix_analog`) — свой
self-hosted аналог Bitrix24: FastAPI + PostgreSQL + React/nginx, три
контейнера (`db`, `server`, `client`), плюс встроенная поддержка единого
входа через любой OIDC-провайдер (`server/app/services/sso.py`) — можно
подключить к уже поднятому в этом стеке Keycloak, второй Keycloak не
нужен.

Технические идентификаторы внутри репозитория (имя проекта Docker
Compose — `taskboard`, имена томов, package id Android-приложения)
переименование в 2btask не тронуло намеренно, чтобы не увести боевые
данные в новые пустые тома — только видимые названия (шапка, заголовок
вкладки, README, Android-приложение). В командах ниже это означает:
каталог на сервере и Traefik-лейблы называются `2btask` (публичное имя),
а `docker compose ps` показывает контейнеры с префиксом `taskboard-*`
(внутреннее имя проекта) — это ожидаемо, не рассинхрон.

В отличие от Plane/DefectDojo это не вендорский многосервисный
дистрибутив — код и `docker-compose.yml` полностью свои, поэтому
устанавливаем не официальным инсталлятором, а обычным `git clone` +
патч поверх `docker-compose.yml` для интеграции с Traefik/Homepage,
как и остальные сервисы платформы.

Заменяет Plane на том же поддомене `2btask.${BASE_DOMAIN}` — Plane при этом
демонтируется (см. шаг 0).

## 0. Снести Plane

```bash
cd /opt/plane/plane-app
docker compose --env-file=plane.env down -v
cd /opt/plane && rm -rf plane-app   # опционально, требует sudo (каталог root:root)
```

`-v` удаляет тома (Postgres/MinIO/Redis/RabbitMQ Plane) — данные не
нужны и не переносятся. Если решите оставить историю на всякий случай —
уберите `-v` и остановитесь на `down` (контейнеры уйдут, том останется
на диске, можно поднять обратно `docker compose up -d` в этой же папке).

## 1. Client в Keycloak

Тем же способом, что и для GitLab/Grafana/n8n (`docs/service-sso.md`):

`https://sso.${BASE_DOMAIN}` → realm **devops** → Clients → Create client.

| Поле | Значение |
|---|---|
| Client ID | `2btask` |
| Client authentication | **On** |
| Valid redirect URIs | `https://2btask.${BASE_DOMAIN}/auth/callback` |
| Web origins | `https://2btask.${BASE_DOMAIN}` |

Сохранить → вкладка **Credentials** → скопировать **Client Secret**,
он понадобится в шаге 3.

Логин по SSO **не заводит** нового сотрудника — он ищет уже существующего
активного пользователя 2btask по email (см. `server/app/services/sso.py`).
Значит: у кого должен быть Keycloak-вход, у того сначала должен появиться
пользователь в 2btask (Сотрудники → добавить) с тем же email, что
и в Keycloak.

## 2. Код на сервер

Сервер не имеет доступа к GitHub (приватный репозиторий) — клонируем
локально и переносим по уже существующему SSH (`devplat`), без токенов
на проде:

```bash
git clone git@github.com:yunisv/2btask.git
rsync -az --exclude .git 2btask/ devplat:~/2btask/
```

## 3. `.env` — продакшен-настройки

На сервере, `~/2btask/.env` (по образцу `.env.example`, но с
реальными значениями):

```bash
CLIENT_PORT=8080
SERVER_PORT=4000
# DB_PORT не публикуется вовсе — см. override в шаге 4

POSTGRES_USER=postgres
POSTGRES_PASSWORD=<openssl rand -hex 32>
POSTGRES_DB=taskboard

JWT_SECRET=<python -c "import secrets; print(secrets.token_urlsafe(48))">
ACCESS_TOKEN_TTL_MINUTES=720
BCRYPT_ROUNDS=12

CORS_ORIGINS=https://2btask.${BASE_DOMAIN}

# Первый запуск заводит администратора и накатывает миграции.
# Демо-данные (2 отдела/3 сотрудника/задачи) на проде не нужны.
SEED_ON_START=true
SEED_DEMO=false
SEED_ADMIN_EMAIL=admin@2btask.az
SEED_ADMIN_PASSWORD=<openssl rand -base64 24>

UNF_ENABLED=false
ASSISTANT_ENABLED=false

# Единый вход — клиент из шага 1
SSO_ENABLED=true
SSO_ISSUER_URL=https://sso.${BASE_DOMAIN}/realms/devops
SSO_CLIENT_ID=2btask
SSO_CLIENT_SECRET=<секрет из шага 1>
SSO_REDIRECT_URI=https://2btask.${BASE_DOMAIN}/auth/callback
```

**Не** поднимать профиль `sso` из `docker-compose.yml` (свой встроенный
Keycloak) — используется уже существующий Keycloak платформы. Команда
запуска ниже (шаг 5) без `--profile sso` его и не тронет.

**После первого входа** сразу сменить `SEED_ADMIN_PASSWORD` через UI
(Профиль → сменить пароль) — значение из `.env` действует только на
самый первый seed, дальше пароль хранится как хэш в базе, `.env` можно
даже стереть.

Запишите `SEED_ADMIN_PASSWORD` и `SSO_CLIENT_SECRET` куда-то помимо
чата — это секреты продакшен-инстанса.

## 4. Traefik + Homepage — `docker-compose.override.yml`

Собственный `docker-compose.yml` 2btask не рассчитан на этот
стек (публикует порты на хост напрямую, никакого `devops_edge`). Вместо
правки чужого (точнее, версионируемого в другом репозитории)
`docker-compose.yml`, накладываем `docker-compose.override.yml` —
Docker Compose подхватывает его автоматически, отдельный `-f` не нужен.

`!reset` (Docker Compose ≥ 2.24 — на сервере v5.1, с запасом) обнуляет
список из базового файла: без него `ports:` в override просто
**добавился** бы к уже существующим публикациям порта, а не заменил их
(list-поля в compose по умолчанию объединяются, не переопределяются —
грабли того же типа, что и `DATABASE_URL`/`AMQP_URL` у Plane в
`adding-plane.md`).

```yaml
# ~/2btask/docker-compose.override.yml
services:
  db:
    ports: !reset []       # никакого 5432 наружу вообще

  server:
    ports: !reset []       # /docs при необходимости — docker exec/SSH-туннель
    networks:
      - default
      - edge          # без этого — httpx.ConnectTimeout на discovery
                       # sso.${BASE_DOMAIN} (тот же hairpin, что и у
                       # oauth2-proxy/gitlab-runner в docker-compose.yml):
                       # `server` дёргает Keycloak сам (build_authorization_url,
                       # exchange_code_for_user), не через браузер клиента

  client:
    ports: !reset []       # наружу только через Traefik
    networks:
      - default
      - edge
    labels:
      - traefik.enable=true
      # У контейнера две сети (свой default проекта + общий edge), Traefik
      # сидит только в edge — без явного указания сети он может выбрать
      # недостижимую и зависнуть на 30s/504 (та же грабля, что в adding-plane.md).
      - traefik.docker.network=devops_edge
      - traefik.http.routers.2btask.rule=Host(`2btask.${BASE_DOMAIN}`)
      - traefik.http.routers.2btask.entrypoints=websecure
      - traefik.http.routers.2btask.middlewares=internal-only@file
      - traefik.http.services.2btask.loadbalancer.server.port=80
      - homepage.group=Development
      - homepage.name=2btask
      - homepage.icon=si-checkmarx.png
      - homepage.href=https://2btask.${BASE_DOMAIN}
      - homepage.description=Учёт задач и трудозатрат

networks:
  edge:
    external: true
    name: devops_edge
```

`loadbalancer.server.port=80` — это внутренний порт nginx в контейнере
`client` (см. `docker-compose.yml`, `client` слушает `80` внутри), не
`CLIENT_PORT` — тот больше никуда не публикуется.

## 5. Запуск

```bash
cd ~/2btask
docker compose up -d --build
docker compose ps        # все Up/healthy (имена контейнеров — taskboard-*,
                          # это внутреннее имя проекта, не переименовано)
```

## 6. Проверка

```bash
# 1. Контейнер клиента реально отвечает изнутри сети edge?
docker exec devops-platform-traefik-1 wget -T 5 -qO- http://taskboard-client-1/ >/dev/null && echo OK

# 2. Снаружи (с пира NetBird)
curl -sI https://2btask.${BASE_DOMAIN} | head -1
```

Открыть `https://2btask.${BASE_DOMAIN}` — форма входа должна показывать
кнопку Keycloak (её видимость определяется `GET /api/auth/sso/status`
на фронте, публичная проба). Войти паролем администратора, сразу
сменить пароль, завести реальных сотрудников с их корпоративными email —
после этого им доступен вход через Keycloak.

## Ресурсы

Заметно легче Plane: три контейнера вместо восьми, без
Redis/RabbitMQ/MinIO. Снятие Plane освобождает больше, чем добавляет
2btask.
