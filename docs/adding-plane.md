# Подключение Plane (issue tracking / PM)

Как и DefectDojo/Harbor, Plane не описан в этом скелете как ещё один
`docker-compose.*.yml`: официальный self-hosted дистрибутив — это
Postgres, Redis, RabbitMQ, MinIO, web, admin, api, worker, beat-worker,
live и встроенный Caddy-прокси, собираемые официальным установщиком в
отдельную папку `plane-app/`. Копирование этого набора к себе вручную
быстро разойдётся с апстримом при апдейтах — ставим официально и
подключаем к общей сети `devops_edge`.

Ниже — рабочая последовательность, проверенная на реальном деплое, со
всеми граблями, которые встретились по пути. Порядок шагов важен:
секреты и патч под Traefik делаются **до** первого `docker compose up`,
это экономит один полный цикл пересоздания БД/очереди.

## 1. Установка

Установщик раздаётся через GitHub Releases, а не сырым файлом из дерева
репозитория (`deploy/selfhost/install.sh` больше не существует — 404):

```bash
mkdir -p /opt/plane && cd /opt/plane
curl -fsSL -o setup.sh https://github.com/makeplane/plane/releases/latest/download/setup.sh
chmod +x setup.sh
```

**Известный баг установщика**: `setup.sh` внутри делает
`export APP_RELEASE=$(checkLatestRelease)`, а `checkLatestRelease()` при
неудаче обращения к `api.github.com` (rate limit/сетевые нюансы) делает
`exit 1` — но это `exit` внутри `$(...)`, он завершает только подпроцесс,
а не весь скрипт. В итоге `APP_RELEASE` тихо становится пустой строкой,
и установка падает дальше на `invalid reference format` /
`Invalid arguments supplied`. Если увидели `Failed to check for the
latest release` — пропатчите строку с дефолтом на конкретный тег
(проверьте актуальный на
[github.com/makeplane/plane/releases/latest](https://github.com/makeplane/plane/releases/latest)):

```bash
sed -i 's/^export APP_RELEASE=stable$/export APP_RELEASE=v1.4.0/' setup.sh
```

Дальше:

```bash
./setup.sh
# Меню: 1) Install
# Domain: pm.${BASE_DOMAIN} (может не спроситься вообще — тогда правим
#   plane.env руками, см. шаг 2)
# Are you hosting this instance behind a reverse proxy? -> Yes
# Express (Advanced нужен только для внешних БД/Redis/S3 — тут всё встроенное)
```

Установщик создаёт `plane-app/docker-compose.yaml` и `plane-app/plane.env`
и сам пытается поднять контейнеры. Не пугайтесь, если на этом шаге упадёт
с ошибкой про порты 80/443 (Traefik их уже держит) — это ожидаемо, если
патч из шага 3 ещё не применён. Дальше правим `plane.env` и
`docker-compose.yaml` и поднимаем стек сами.

## 2. plane.env: домен и секреты

Мастер установки не всегда реально спрашивает домен (иногда сразу уходит
в `Begin Installing` с `APP_DOMAIN=localhost` по умолчанию) — после
установки обязательно проверить и поправить:

```bash
cd /opt/plane/plane-app
grep -nE "^APP_DOMAIN|^WEB_URL|^CORS_ALLOWED_ORIGINS" plane.env
```

Если `APP_DOMAIN=localhost` или `WEB_URL`/`CORS_ALLOWED_ORIGINS` со
схемой `http://` — поправить (Traefik терминирует TLS, наружу должно
быть `https://`):

```bash
sed -i \
  -e "s#^APP_DOMAIN=.*#APP_DOMAIN=pm.${BASE_DOMAIN}#" \
  -e "s#^WEB_URL=.*#WEB_URL=https://\${APP_DOMAIN}#" \
  -e "s#^CORS_ALLOWED_ORIGINS=.*#CORS_ALLOWED_ORIGINS=https://\${APP_DOMAIN}#" \
  plane.env
```

Дальше сгенерировать реальные секреты вместо плейсхолдеров
(`SECRET_KEY=change-this-key-on-deployment`,
`POSTGRES_PASSWORD=plane`, `RABBITMQ_PASSWORD=plane`,
`AWS_ACCESS_KEY_ID=access-key`/`AWS_SECRET_ACCESS_KEY=secret-key` — это
креды встроенного MinIO, не внешнего S3):

```bash
POSTGRES_PW=$(openssl rand -hex 32)
RABBITMQ_PW=$(openssl rand -hex 32)
SECRET_KEY_VAL=$(openssl rand -hex 32)
LIVE_SECRET_VAL=$(openssl rand -hex 32)
MINIO_ACCESS=$(openssl rand -hex 16)
MINIO_SECRET=$(openssl rand -hex 32)

sed -i \
  -e "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${POSTGRES_PW}#" \
  -e "s#^RABBITMQ_PASSWORD=.*#RABBITMQ_PASSWORD=${RABBITMQ_PW}#" \
  -e "s#^SECRET_KEY=.*#SECRET_KEY=${SECRET_KEY_VAL}#" \
  -e "s#^LIVE_SERVER_SECRET_KEY=.*#LIVE_SERVER_SECRET_KEY=${LIVE_SECRET_VAL}#" \
  -e "s#^AWS_ACCESS_KEY_ID=.*#AWS_ACCESS_KEY_ID=${MINIO_ACCESS}#" \
  -e "s#^AWS_SECRET_ACCESS_KEY=.*#AWS_SECRET_ACCESS_KEY=${MINIO_SECRET}#" \
  -e "s#^DATABASE_URL=.*#DATABASE_URL=postgresql://plane:${POSTGRES_PW}@plane-db:5432/plane#" \
  -e "s#^AMQP_URL=.*#AMQP_URL=amqp://plane:${RABBITMQ_PW}@plane-mq:5672/plane#" \
  plane.env
```

**Критично про `DATABASE_URL`/`AMQP_URL`**: в `docker-compose.yaml` у них
свой fallback, независимый от `POSTGRES_PASSWORD`/`RABBITMQ_PASSWORD`:

```yaml
DATABASE_URL: ${DATABASE_URL:-postgresql://plane:plane@plane-db/plane}
AMQP_URL: ${AMQP_URL:-amqp://plane:plane@plane-mq:5672/plane}
```

Если оставить `DATABASE_URL`/`AMQP_URL` пустыми в `plane.env`, приложение
подключается по захардкоженному `plane:plane`, а Postgres/RabbitMQ при
первой инициализации получает ваш новый пароль — рассинхрон и
`password authentication failed` / `403 ACCESS_REFUSED`. Прописывать эти
две переменные явно, с тем же паролем, что и в `POSTGRES_PASSWORD`/
`RABBITMQ_PASSWORD`, — обязательно (сделано в команде выше).

Не трогать: `API_BASE_URL`, `CERT_EMAIL`/`CERT_ACME_CA`/`CERT_ACME_DNS`/
`SITE_ADDRESS` (Traefik уже терминирует TLS, встроенный Caddy отдаёт
только плейн HTTP на `:80`), `TRUSTED_PROXIES=0.0.0.0/0` (безопасно —
бэкенд-контейнеры не смотрят во внешнюю сеть напрямую), количество
реплик, `DOCKERHUB_USER`/`PULL_POLICY`/`CUSTOM_BUILD`.

## 3. Подключение к Traefik вместо встроенного Caddy

У Plane свой встроенный прокси (Caddy, слушает 80/443) — TLS у нас уже
терминирует Traefik, поэтому порты наружу не пробрасываем, а сам
прокси-сервис подключаем к `devops_edge` и вешаем Traefik-лейблы. Это
генерируемый файл (не наш, обновляется установщиком Plane), правится
напрямую в `plane-app/docker-compose.yaml`, у сервиса `proxy`.

Из блока `proxy` удалить весь `ports:` целиком (в актуальной версии это
long-syntax с `target`/`published`/`mode: host` через
`LISTEN_HTTP_PORT`/`LISTEN_HTTPS_PORT`), добавить `networks:` и
`labels:`:

```yaml
  proxy:
    image: makeplane/plane-proxy:${APP_RELEASE:-v1.4.0}
    deploy:
      replicas: 1
      restart_policy:
        condition: any
    environment:
      <<: *proxy-env
    networks:
      - default
      - edge
    volumes:
      - proxy_config:/config
      - proxy_data:/data
    depends_on:
      - web
      - api
      - space
      - admin
      - live
    labels:
      - traefik.enable=true
      # Обязательно: у этого контейнера ДВЕ сети (свой default проекта +
      # общий edge), а Traefik сидит только в edge. Без явного указания
      # сети Traefik может выбрать недостижимую для себя сеть контейнера
      # и виснуть на dial-timeout (ровно 30s, "504 Gateway Timeout") —
      # при этом прямой docker exec/wget внутри контейнеров работает,
      # что маскирует настоящую причину.
      - traefik.docker.network=devops_edge
      - traefik.http.routers.plane.rule=Host(`pm.${BASE_DOMAIN}`)
      - traefik.http.routers.plane.entrypoints=websecure
      - traefik.http.routers.plane.middlewares=internal-only@file
      - traefik.http.services.plane.loadbalancer.server.port=80
      # НЕ добавлять tls.certresolver сюда: сертификат этот роутер получает
      # от entrypoint websecure (там уже включён TLS по умолчанию, а
      # единственный wildcard-запрос живёт на роутере traefik в основном
      # docker-compose.yml). Свой certresolver на этом роутере закажет ещё
      # один отдельный сертификат именно на pm.${BASE_DOMAIN} — тот самый
      # баг, который уже чинили в основном стеке (traefik/traefik#12109),
      # и он же снова выведет этот поддомен в публичные CT-логи.
      # Homepage видит любой контейнер на хосте через docker.sock, вне
      # зависимости от compose-проекта — этих лейблов достаточно, чтобы
      # плитка появилась на dash.${BASE_DOMAIN} сама.
      - homepage.group=Development
      - homepage.name=Plane
      - homepage.icon=plane.png
      - homepage.href=https://pm.${BASE_DOMAIN}
      - homepage.description=Issue tracking / PM

networks:
  edge:
    external: true
    name: devops_edge
```

Если у сервиса `proxy` в файле ещё нет секции `networks:` в корне
(некоторые версии установщика её не создают) — добавить целиком в конец
файла, как показано выше.

## 4. Запуск — обязательно с `--env-file`

**Всегда** запускать compose в этой папке с явным `--env-file=plane.env`
— именно так это делает официальный `setup.sh` внутри себя
(`docker compose -f docker-compose.yaml --env-file=plane.env up -d`).
Без этого флага Docker Compose использует для подстановки `${VAR}` в
`docker-compose.yaml` файл `.env` в текущей папке (которого нет), а не
`plane.env` — все переменные без fallback-значения (`SECRET_KEY`,
`CORS_ALLOWED_ORIGINS`, `CERT_*` и т.д.) молча превращаются в пустую
строку, а те, у кого fallback есть (например, RabbitMQ-креды в
`x-mq-env`), тихо откатываются на дефолт `plane`/`plane` — именно так
рассинхронизируются пароли между сервисами, даже если в `plane.env` всё
прописано верно.

```bash
cd /opt/plane/plane-app
docker compose --env-file=plane.env up -d
docker compose --env-file=plane.env ps
```

Проверка: в выводе не должно быть строк `WARN[0000] The "X" variable is
not set`, и ни один сервис не должен быть в рестарт-лупе (особенно
`migrator`/`api`/`worker` — это обычно первый симптом рассинхрона
паролей с БД/очередью).

Не переименовывать `plane.env` в `.env` и не делать на него симлинк —
`setup.sh` (в том числе `./setup.sh upgrade`) хардкодит имя `plane.env`
во всех операциях (`pull`/`up`/`down`), полагаясь на явный
`--env-file=plane.env`. Проще всего один раз завести алиас на сессию/в
`~/.bashrc`:

```bash
alias plane-compose='docker compose --env-file=plane.env'
```

При апгрейде (`./setup.sh upgrade`) установщик может перезаписать
`docker-compose.yaml` целиком — после апгрейда сверить, что патч для
`proxy` (шаг 3) не затёрся.

## Диагностика: 504 Gateway Timeout при рабочих контейнерах

Если все контейнеры `Up`/`healthy`, а `https://pm.${BASE_DOMAIN}` отдаёт
`504` — прежде чем что-то менять, проверьте гипотезы по порядку:

```bash
# 1. Реально ли Traefik может достучаться до proxy по сети?
docker exec devops-platform-traefik-1 wget -T 5 -qO- http://plane-app-proxy-1/

# 2. В каких сетях контейнер прокси, и видит ли его devops_edge
docker network inspect devops_edge --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
docker inspect plane-app-proxy-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
```

Если шаг 1 отвечает мгновенно и корректным HTML, а сам запрос через
Traefik всё равно висит ровно ~30 секунд и потом отдаёт 504 — почти
наверняка не хватает `traefik.docker.network=devops_edge` (см. шаг 3).

## Интеграция с GitLab и n8n (для AI-агентов)

1. В Plane: Workspace Settings → Integrations → GitLab, указать `https://git.${BASE_DOMAIN}` и токен пользователя-бота GitLab с правами `api`.
2. Привязать репозиторий проекта GitLab к проекту в Plane — дальше статусы MR подтягиваются в Plane автоматически.
3. Workspace Settings → Webhooks → добавить `https://automation.${BASE_DOMAIN}/webhook/plane` (n8n) — события по задачам (создание/обновление/переход статуса) идут в n8n тем же способом, что и вебхуки GitLab/DefectDojo (см. `ai-agents-roadmap.md`). Если хост n8n — адрес в сети NetBird (CGNAT-диапазон), может понадобиться добавить его в `WEBHOOK_ALLOWED_HOSTS` в `plane.env`, иначе сработает встроенная защита от SSRF на приватные адреса.
4. Для скриптовых интеграций/агентов — Personal Access Token в Plane (Account Settings → API tokens), REST API описан на `developers.plane.so/api-reference`.

## Ресурсы

Официальный минимум — 2 vCPU / 4GB RAM, но это без учёта RabbitMQ/MinIO под
реальной нагрузкой нескольких команд: закладывайте **4 vCPU / 6-8GB** сверх
основного стека (см. обновлённую таблицу в `architecture.md`).
