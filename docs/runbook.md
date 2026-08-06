# Runbook: карта платформы и статус этого деплоя

Остальные доки объясняют, *как* настроить конкретную вещь. Этот файл —
единая точка входа: что вообще есть, кто за что отвечает, где это
настроено, и что из этого уже реально сделано именно на этом сервере.

## Карта сервисов

| Сервис | Поддомен | За что отвечает | Порт (внутри контейнера) | Где настроено |
|---|---|---|---|---|
| Traefik | `traefik.` | reverse proxy, TLS (один wildcard-сертификат через DNS-01/Hetzner), ip-фильтр внутренних сервисов | — (сам прокси) | `docker-compose.yml` |
| Keycloak | `sso.` | SSO **для сервисов платформы** (GitLab/Grafana/dashboard). **Не** отвечает за вход в VPN — это делает NetBird отдельно | 8080 | `docker-compose.yml` |
| GitLab CE | `git.` | git, merge requests, CI/CD, issue-доски, встроенный SAST | 80 | `docker-compose.gitlab.yml` |
| GitLab Container Registry | `registry.` | docker-образы из CI | 5050 | `docker-compose.gitlab.yml` |
| GitLab Runner | — (внутренний) | исполняет CI-джобы (docker executor) | — | `docker-compose.gitlab.yml`, профиль `runner` |
| Prometheus | `prometheus.` | сбор метрик (node-exporter, cAdvisor, GitLab, Traefik) | 9090 | `docker-compose.monitoring.yml` |
| Grafana | `grafana.` | дашборды: Node Exporter Full, Docker Containers | 3000 | `docker-compose.monitoring.yml` |
| Alertmanager | `alerts.` | маршрутизация алертов → webhook в n8n | 9093 | `docker-compose.monitoring.yml`, `config/alertmanager/` |
| Loki + Promtail | — (внутренние, смотреть через Grafana) | логи всех контейнеров | — | `docker-compose.monitoring.yml` |
| node-exporter / cAdvisor | — (внутренние) | метрики хоста / метрики контейнеров | — | `docker-compose.monitoring.yml` |
| n8n | `automation.` | автоматизация вебхуков, площадка для будущих AI-агентов | 5678 | `docker-compose.automation.yml` |
| Homepage | `dash.` | стартовая страница со всеми сервисами (auto-discovery по docker-лейблам) | 3000 | `docker-compose.dashboard.yml` |
| oauth2-proxy | (обслуживает `dash.`) | SSO-гейт перед Homepage через Keycloak | 4180 | `docker-compose.dashboard.yml` |
| Plane | `pm.` | issue tracking / PM | — | `docs/adding-plane.md` (официальный установщик, не наш compose) |
| DefectDojo | `dojo.` | агрегация находок SAST/DAST/SCA | — | `docs/adding-defectdojo-harbor.md` (официальный установщик) |
| NetBird (control plane) | `netbird.` — **на отдельном сервере** | единственная точка входа в платформу | — | `docs/vpn-netbird.md` |

Всё, кроме `sso.` и `netbird.` (тот вообще на другом сервере), закрыто
middleware `internal-only@file` — отвечает только пирам сети NetBird.

## Сетевая модель (коротко)

```
клиент → NetBird (отдельный сервер, control plane) → этот сервер (DevPlat),
подключён к сети NetBird как обычный peer
```

У DevPlat нет ни одного публичного входящего порта. Traefik и git-по-SSH
слушают только `BIND_ADDRESS` — IP этого сервера в сети NetBird, не
публичный интерфейс. Подробности и топология — `docs/vpn-netbird.md`.

## Где что лежит

- **Переменные окружения** — `.env` (не в git), структура/комментарии — в `.env.example`.
- **Пароли** — сгенерированы `scripts/install.sh` при первом запуске, лежат только в `.env`. Traefik dashboard — отдельно, `secrets/dashboard.htpasswd`.
- **Секретные токены** (`HETZNER_API_TOKEN`, `GITLAB_RUNNER_TOKEN`, `OAUTH2_PROXY_CLIENT_SECRET`) — тоже в `.env`, вписываются вручную по ходу настройки.
- **Бэкапы** — `scripts/backup.sh`, инструкция и restore — `docs/backups.md`.

## Статус этого деплоя

Снимок на **2026-08-06**. Дальше руками поддерживать актуальность (или
попросить обновить при следующей сессии) — этот раздел не отслеживается
автоматически.

**Домен:** `devops.2be.az` (зона `2be.az` делегирована на Hetzner DNS)
**Сервер платформы:** DevPlat, Hetzner Cloud, `eu-central`
**NetBird control plane:** отдельный CX22, `netbird.2be.az`

| Готово | Пункт |
|---|---|
| ✅ | Core (Traefik + Keycloak) |
| ✅ | GitLab CE + Runner (зарегистрирован и подхватывает джобы) |
| ✅ | Мониторинг: Prometheus/Grafana (с дашбордами)/Loki/Alertmanager |
| ✅ | n8n — owner-аккаунт создан |
| ✅ | Homepage (dashboard) за Keycloak SSO |
| ✅ | NetBird: control plane + DevPlat как peer |
| 🔄 | `harden.sh` — выполняется по ходу этой сессии |
| 🔄 | SSH: непривилегированный пользователь + `PermitRootLogin no` — выполняется |
| ⬜ | Cron для `scripts/backup.sh` + копирование архивов с сервера |
| ✅ | Plane — установлен, работает за Traefik (`pm.devops.2be.az`) |
| 🔄 | DefectDojo — установка |
| ⬜ | n8n: workflow с Webhook-триггером на `/webhook/alertmanager` (иначе алерты уходят в никуда) |
| ⬜ | Первый проект в GitLab + тестовый `.gitlab-ci.yml` |
| ⬜ | NetBird Access Control (пока не настроено — актуально, когда подключится больше людей) |
| ⬜ | AI-агенты в n8n (`docs/ai-agents-roadmap.md`) |

## Быстрые ссылки

- Общий обзор и quick start — [README.md](../README.md)
- Архитектура и обоснование выбора инструментов — [architecture.md](architecture.md)
- Сеть и VPN — [vpn-netbird.md](vpn-netbird.md)
- Дашборд и SSO — [dashboard-sso.md](dashboard-sso.md)
- Бэкапы — [backups.md](backups.md)
- Plane / DefectDojo — [adding-plane.md](adding-plane.md), [adding-defectdojo-harbor.md](adding-defectdojo-harbor.md)
- AI-агенты (roadmap) — [ai-agents-roadmap.md](ai-agents-roadmap.md)
