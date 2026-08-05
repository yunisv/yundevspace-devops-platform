# Подключение Plane (issue tracking / PM)

Как и DefectDojo/Harbor, Plane не описан в этом скелете как ещё один
`docker-compose.*.yml`: официальный self-hosted дистрибутив — это 7-8
сервисов (Postgres, Redis, RabbitMQ, MinIO, web, admin, api, worker,
beat-worker, live, встроенный Caddy-прокси), собираемые официальным
установщиком в отдельную папку `plane-app/`. Копирование этого набора к
себе вручную быстро разойдётся с апстримом при апдейтах — ставим
официально и подключаем к общей сети `devops_edge`.

## Установка

Репозиторий Plane пересобрали (`deploy/` стал `deployments/` с несколькими
методами — cli/aio/kubernetes/swarm), установщик теперь раздаётся через
GitHub Releases, а не сырым файлом из дерева репозитория — если увидите
`curl: (22) ... 404` на старый путь `deploy/selfhost/install.sh`, вот
актуальный:

```bash
mkdir -p /opt/plane && cd /opt/plane
curl -fsSL -o setup.sh https://github.com/makeplane/plane/releases/latest/download/setup.sh
chmod +x setup.sh
./setup.sh
# Меню: 1) Install — создаёт папку plane-app/ с docker-compose.yaml и plane.env
```

В `plane-app/plane.env` выставить:

```bash
WEB_URL=https://pm.${BASE_DOMAIN}
```

## Подключение к Traefik вместо встроенного Caddy

У Plane свой встроенный прокси (слушает 80/443) — TLS у нас уже терминирует
Traefik, поэтому порты наружу не пробрасываем, а сам прокси-сервис
подключаем к `devops_edge` и вешаем Traefik-лейблы. Это генерируемый
файл (не наш, обновляется установщиком Plane), поэтому правим его
напрямую после `./setup.sh install`, в `plane-app/docker-compose.yaml`,
у сервиса прокси (обычно называется `proxy`):

```yaml
services:
  proxy:
    # Удалить весь блок `ports:` целиком — в актуальной версии он выглядит
    # как long-syntax с target/published/mode: host (через LISTEN_HTTP_PORT/
    # LISTEN_HTTPS_PORT), а не простой `["80:80"]", но смысл тот же: наружу
    # это будет отдавать Traefik, а не сам Plane.
    networks:
      - default
      - edge
    labels:
      - traefik.enable=true
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
      # и он же снова выведет это поддомен в публичные CT-логи.

networks:
  edge:
    external: true
    name: devops_edge
```

Запуск: `cd /opt/plane/plane-app && docker compose up -d`. При апгрейде
Plane (`./setup.sh upgrade`) установщик может перезаписать
`docker-compose.yaml` — после апгрейда стоит сверить, что правки для
`proxy` не затёрлись.

## Интеграция с GitLab и n8n (для AI-агентов)

1. В Plane: Workspace Settings → Integrations → GitLab, указать `https://git.${BASE_DOMAIN}` и токен пользователя-бота GitLab с правами `api`.
2. Привязать репозиторий проекта GitLab к проекту в Plane — дальше статусы MR подтягиваются в Plane автоматически.
3. Workspace Settings → Webhooks → добавить `https://automation.${BASE_DOMAIN}/webhook/plane` (n8n) — события по задачам (создание/обновление/переход статуса) идут в n8n тем же способом, что и вебхуки GitLab/DefectDojo (см. `ai-agents-roadmap.md`).
4. Для скриптовых интеграций/агентов — Personal Access Token в Plane (Account Settings → API tokens), REST API описан на `developers.plane.so/api-reference`.

## Ресурсы

Официальный минимум — 2 vCPU / 4GB RAM, но это без учёта RabbitMQ/MinIO под
реальной нагрузкой нескольких команд: закладывайте **4 vCPU / 6-8GB** сверх
основного стека (см. обновлённую таблицу в `architecture.md`).
