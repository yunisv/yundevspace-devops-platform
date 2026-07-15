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

```bash
git clone https://github.com/DefectDojo/django-DefectDojo.git
cd django-DefectDojo
# docker-compose.yml из репозитория DefectDojo — использовать как есть,
# добавив внешнюю сеть devops_edge к сервису nginx (см. ниже) и убрав
# проброс портов наружу, раз это будет делать Traefik.
```

В `docker-compose.override.yml` рядом:

```yaml
services:
  nginx:
    networks:
      - default
      - edge
    labels:
      - traefik.enable=true
      - traefik.http.routers.dojo.rule=Host(`dojo.${BASE_DOMAIN}`)
      - traefik.http.routers.dojo.entrypoints=websecure
      - traefik.http.routers.dojo.tls.certresolver=le
      - traefik.http.services.dojo.loadbalancer.server.port=8443
      - traefik.http.services.dojo.loadbalancer.server.scheme=https

networks:
  edge:
    external: true
    name: devops_edge
```

Дальше — `docker compose up -d` из инструкции DefectDojo. API-токен из
DefectDojo используется в GitLab CI-пайплайнах для `import-scan`/
`reimport-scan` (см. пример в `architecture.md`).

## Harbor (если всё же понадобится)

```bash
wget https://github.com/goharbor/harbor/releases/download/v2.11.1/harbor-online-installer-v2.11.1.tgz
tar xzf harbor-online-installer-v2.11.1.tgz && cd harbor
cp harbor.yml.tmpl harbor.yml
```

В `harbor.yml` указать `hostname: registry.${BASE_DOMAIN}`, отключить
встроенный TLS-терминатор Harbor (`https:` секцию закомментировать — TLS
будет терминировать Traefik), затем:

```bash
./prepare
./install.sh
```

После установки подключить прокси-контейнер Harbor к сети `devops_edge`
так же, как DefectDojo выше, и добавить Traefik-лейблы на нужный порт.

## Интеграция с CI

- GitLab CI → `docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA` (registry + Trivy-сканирование встроены, отдельный Harbor не нужен).
- Trivy/GitLab SAST отчёты → DefectDojo import (единая база находок по всем инструментам) или напрямую в GitLab Issues как задача при critical/high находках.
