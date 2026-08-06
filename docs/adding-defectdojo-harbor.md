# Подключение DefectDojo и (опционально) Harbor

DefectDojo намеренно не описан как ещё один `docker-compose.*.yml` в этом
скелете: у проекта свой официальный многоконтейнерный дистрибутив (Celery
worker + Redis + Nginx + uWSGI), который быстро расходится с апстримом при
копировании. Правильный путь — ставить его официальными средствами и
подключать к общей сети `devops_edge`.

Harbor в этой версии стека, как правило, не нужен вообще: GitLab CE уже
даёт свой Container Registry с встроенным Trivy-сканированием образов на
push. Harbor имеет смысл добавлять отдельно только если понадобится
что-то, чего в GitLab-registry нет (например, репликация между
registry несколькими сайтами, более гибкая RBAC-модель на уровне
проектов registry, или P2P-раздача образов через Dragonfly для очень
большого кластера — для 10-50 разработчиков это обычно избыточно).

## DefectDojo

Официальный quick-start — просто `docker compose up` без отдельного шага
генерации `.env` (в отличие от Plane, здесь compose сам подхватывает
`.env` из текущей папки — стандартное поведение Docker Compose, никакого
`--env-file` не нужно). Но прежде чем поднимать, стоит завести `.env` с
реальными секретами и адресом — иначе всё встанет на дефолтах прямо из
`docker-compose.yml` (открытый repo, значения всем известны):

```bash
git clone https://github.com/DefectDojo/django-DefectDojo.git
cd django-DefectDojo
```

Создать `.env` рядом с `docker-compose.yml`:

```bash
DD_SECRET_KEY_VAL=$(openssl rand -hex 32)
DD_AES_KEY_VAL=$(openssl rand -hex 16)   # ровно 32 символа — под AES-256
DD_DB_PW=$(openssl rand -hex 32)

cat > .env <<EOF
DD_ALLOWED_HOSTS=dojo.${BASE_DOMAIN}
DD_SECRET_KEY=${DD_SECRET_KEY_VAL}
DD_CREDENTIAL_AES_256_KEY=${DD_AES_KEY_VAL}
DD_DATABASE_PASSWORD=${DD_DB_PW}
DD_DATABASE_URL=postgresql://defectdojo:${DD_DB_PW}@postgres:5432/defectdojo
EOF
```

**Та же ловушка, что была с Plane**: в `docker-compose.yml` у
`DD_DATABASE_URL` свой дефолт, независимый от `DD_DATABASE_PASSWORD`:

```yaml
DD_DATABASE_URL: ${DD_DATABASE_URL:-postgresql://defectdojo:defectdojo@postgres:5432/defectdojo}
```

Если сменить только `DD_DATABASE_PASSWORD` и оставить `DD_DATABASE_URL`
пустым/не заданным — Postgres проинициализируется новым паролем, а
Django-контейнеры продолжат подключаться дефолтным `defectdojo:defectdojo`
(из фолбэка `DD_DATABASE_URL`) — рассинхрон и `password authentication
failed`. Прописывать `DD_DATABASE_URL` явно с тем же паролем — обязательно
(сделано в команде выше).

`docker-compose.yml` не объявляет верхнеуровневую секцию `networks:`
вообще — Compose всё равно создаёт неявную сеть `default` для сервисов
без своего `networks:`, так что добавление своей `edge` в
`docker-compose.override.yml` (автоматически подхватывается Compose'ом
рядом с основным файлом, без `-f`) ничего не ломает:

**Важно про `ports:`**: в override НЕДОСТАТОЧНО просто не упомянуть
`ports:` — Compose не заменяет списки (`ports:`/`volumes:`/`expose:`)
между файлами, а добавляет override поверх базового значения. Раз в
`docker-compose.yml` у `nginx` уже есть `ports: [8080:8080, 8443:8443]`
на `0.0.0.0`, без явного сброса они остаются висеть наружу параллельно с
роутингом через Traefik — то есть DefectDojo будет доступен и по VPN
через `dojo.${BASE_DOMAIN}`, и напрямую по публичному IP сервера на 8080/
8443, в обход NetBird. `ufw` тут не спасёт даже если `harden.sh` уже
применён: Docker вставляет свои разрешающие правила в цепочку `DOCKER`,
которая обрабатывается раньше цепочки `INPUT`, где живут правила ufw —
классический и часто упускаемый нюанс связки Docker+ufw. Сбрасывать
список нужно явно, тегом `!reset` (Docker Compose v2.24+):

```yaml
services:
  nginx:
    ports: !reset []
    networks:
      - default
      - edge
    labels:
      - traefik.enable=true
      # Обязательно, если у контейнера больше одной сети — иначе Traefik
      # может выбрать недостижимую для себя сеть и виснуть на dial-timeout
      # (see adding-plane.md, тот же баг словили там на 504 Gateway Timeout).
      - traefik.docker.network=devops_edge
      - traefik.http.routers.dojo.rule=Host(`dojo.${BASE_DOMAIN}`)
      - traefik.http.routers.dojo.entrypoints=websecure
      - traefik.http.routers.dojo.middlewares=internal-only@file
      # Порт 8080 (обычный HTTP), не 8443/https — nginx у DefectDojo и так
      # слушает оба порта одновременно, но раз TLS уже терминирует Traefik,
      # незачем городить второй слой TLS с самоподписанным сертификатом
      # у себя за ним.
      - traefik.http.services.dojo.loadbalancer.server.port=8080
      # НЕ добавлять tls.certresolver сюда — см. пояснение в adding-plane.md
      # (entrypoint уже отдаёт TLS по умолчанию, wildcard заказывается
      # только одним роутером в основном docker-compose.yml).
      # Homepage видит любой контейнер на хосте через docker.sock, вне
      # зависимости от compose-проекта — этих лейблов достаточно, чтобы
      # плитка появилась на dash.${BASE_DOMAIN} сама.
      - homepage.group=Security
      - homepage.name=DefectDojo
      - homepage.icon=defectdojo.png
      - homepage.href=https://dojo.${BASE_DOMAIN}
      - homepage.description=Агрегация находок SAST/DAST/SCA

networks:
  edge:
    external: true
    name: devops_edge
```

Дальше:

```bash
docker compose up -d
docker compose logs initializer | grep "Admin password:"
```

Первая инициализация занимает до 3 минут. Если `https://dojo.${BASE_DOMAIN}`
не отвечает при живых контейнерах (или висит ровно ~30 секунд и потом
`504`) — та же диагностика, что в `adding-plane.md` (раздел
"Диагностика: 504 Gateway Timeout"): проверить `docker exec
devops-platform-traefik-1 wget -T 5 -qO- http://<имя-контейнера-nginx>/`
и убедиться, что `traefik.docker.network` действительно стоит.

API-токен из DefectDojo используется в GitLab CI-пайплайнах для
`import-scan`/`reimport-scan` (см. пример в `architecture.md`).

## Harbor (если всё же понадобится)

```bash
wget https://github.com/goharbor/harbor/releases/download/v2.11.1/harbor-online-installer-v2.11.1.tgz
tar xzf harbor-online-installer-v2.11.1.tgz && cd harbor
cp harbor.yml.tmpl harbor.yml
```

В `harbor.yml` указать `hostname: harbor.${BASE_DOMAIN}` — **не**
`registry.${BASE_DOMAIN}`, этот поддомен уже занят Container Registry
самого GitLab (см. `docker-compose.gitlab.yml`). Отключить встроенный
TLS-терминатор Harbor (`https:` секцию закомментировать — TLS будет
терминировать Traefik), затем:

```bash
./prepare
./install.sh
```

После установки подключить прокси-контейнер Harbor к сети `devops_edge`
так же, как DefectDojo выше (роутер на `harbor.${BASE_DOMAIN}`,
`middlewares=internal-only@file`, без своего `tls.certresolver`), и
добавить Traefik-лейблы на нужный порт.

## Интеграция с CI

- GitLab CI → `docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA` (registry + Trivy-сканирование встроены, отдельный Harbor не нужен).
- Trivy/GitLab SAST отчёты → DefectDojo import (единая база находок по всем инструментам) или напрямую в GitLab Issues как задача при critical/high находках.
