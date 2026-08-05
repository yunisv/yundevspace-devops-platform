# DevOps-платформа компании

Docker-based скелет внутренней платформы для команды 10-50 разработчиков:
VCS + CI/CD + registry + SAST (через GitLab CE), управление задачами/PM
(Plane), управление уязвимостями (DefectDojo), мониторинг и слой
автоматизации с заделом под AI-агентов (n8n). Подробная архитектура и
обоснование выбора — в [docs/architecture.md](docs/architecture.md).

Ядро — **GitLab CE**, а не набор из отдельных Gitea/Jira/SonarQube: это
единственный вариант в этом пространстве, реально проверенный боем именно
на масштабе 10-50+ разработчиков как цельный продукт, а не сборка из
нескольких вендоров. Взамен на меньшую гибкость получаем сильно меньше
интеграционной работы. Остальные сервисы — то, чего GitLab сам не делает.

## Состав

| Слой | Файл | Сервисы |
|---|---|---|
| Core (обязателен) | `docker-compose.yml` | Traefik (reverse proxy + TLS), Keycloak (SSO) |
| VCS + CI/CD + Issues + Registry + SAST | `docker-compose.gitlab.yml` | GitLab CE, GitLab Runner |
| Мониторинг | `docker-compose.monitoring.yml` | Prometheus, Grafana, Loki, Promtail, Alertmanager, node-exporter, cAdvisor |
| Автоматизация / AI-агенты | `docker-compose.automation.yml` | n8n |
| Стартовая страница + SSO | `docker-compose.dashboard.yml` | Homepage, oauth2-proxy |

Стартовая страница (`dash.`) собирает плитки сервисов **автоматически** из
docker-лейблов `homepage.*` — добавили сервис в стек, он появился на
странице. Подробности и настройка SSO — в
[docs/dashboard-sso.md](docs/dashboard-sso.md).

Plane (issue tracking/PM), DefectDojo (агрегация находок SAST/DAST/SCA) и
Harbor (registry с расширенным сканированием, если GitLab-registry+Trivy
окажется недостаточно) подключаются отдельно официальными установщиками —
их self-hosted дистрибутивы это 5-8 взаимозависимых сервисов каждый,
вендорить такое в свой compose и держать в синхроне с апстримом не стоит.
Инструкции: [docs/adding-plane.md](docs/adding-plane.md),
[docs/adding-defectdojo-harbor.md](docs/adding-defectdojo-harbor.md).
Roadmap по AI-агентам — в [docs/ai-agents-roadmap.md](docs/ai-agents-roadmap.md).

## Быстрый старт

Требования: свежий сервер Ubuntu/Debian, **минимум 8GB RAM только под
GitLab** (см. таблицу ресурсов ниже), домен на Hetzner DNS с API-токеном
(`HETZNER_API_KEY` в `.env`) и DNS, указывающий на сервер — проще всего
wildcard `*.${BASE_DOMAIN}`, иначе A-записи на каждый поддомен:

`git`, `registry`, `sso`, `traefik`, `grafana`, `prometheus`, `alerts`,
`automation`, `dash` (+ `pm` и `dojo`, если ставите Plane/DefectDojo).
Записи указывают на IP этого сервера **в сети NetBird**, не на публичный —
см. [docs/vpn-netbird.md](docs/vpn-netbird.md), его нужно поставить и
подключить этот сервер как peer до запуска `install.sh`.

Сертификаты выпускаются через DNS-01 challenge (TXT-запись), поэтому порт 80
открывать не нужно вообще, а на всю платформу выдаётся один wildcard-сертификат.
Без `HETZNER_API_KEY` установка остановится с ошибкой — Let's Encrypt не
сможет подтвердить домен.

Один файл на сервере — ставит Docker (если его нет), настраивает sysctl,
сеть, генерирует случайные секреты в `.env`, поднимает выбранные слои:

```bash
git clone <url-этого-репозитория> devops-platform && cd devops-platform
sudo ./scripts/install.sh                       # gitlab + мониторинг + автоматизация
# sudo ./scripts/install.sh --minimal            # только core + GitLab
# sudo ./scripts/install.sh --layers="gitlab automation"  # свой набор слоёв
```

Скрипт идемпотентен — его можно перезапускать (не трогает уже
существующий `.env`, пропускает уже установленные пакеты). Он спросит
`BASE_DOMAIN` и `ACME_EMAIL` интерактивно, либо возьмёт их из переменных
окружения для неинтерактивного запуска, и один раз выведет
сгенерированный пароль от Traefik dashboard — сохраните его сразу, второй
раз он нигде не показывается (лежит только как bcrypt-хэш в
`secrets/dashboard.htpasswd`).

Если сервер не Ubuntu/Debian — ставьте Docker + Compose plugin вручную,
затем `cp .env.example .env`, заполните и запускайте `./scripts/up.sh
<слои>` напрямую (то, что `install.sh` делает поверх этого — только ОС-специфичные шаги).

После первого запуска (GitLab поднимается 3-5 минут при первом старте):

1. `https://sso.${BASE_DOMAIN}` — создать realm/клиентов в Keycloak для остальных сервисов.
2. `https://git.${BASE_DOMAIN}` — залогиниться как `root` / `GITLAB_ROOT_PASSWORD`, создать первую группу/проект.
3. Admin Area → CI/CD → Runners → New instance runner — скопировать токен, прописать в `.env` как `GITLAB_RUNNER_TOKEN`, поднять раннер (он в профиле `runner`, поэтому сам не стартует): `docker compose -f docker-compose.yml -f docker-compose.gitlab.yml --profile runner up -d`
4. `https://grafana.${BASE_DOMAIN}` — датасорсы Prometheus/Loki уже прописаны автоматически.
5. `https://automation.${BASE_DOMAIN}` — **сразу создать owner-аккаунт** (n8n убрал basic-auth в версии 1.0, доступ закрывает только собственный аккаунт — пока он не создан, занять его может любой, кто откроет адрес), затем настроить workflow'ы под вебхуки GitLab/Plane/DefectDojo/Alertmanager.
6. Стартовая страница `https://dash.${BASE_DOMAIN}` со всеми сервисами — поднимается отдельно, после настройки realm/клиента в Keycloak: [docs/dashboard-sso.md](docs/dashboard-sso.md), затем `./scripts/up.sh dashboard`.
7. Plane ставится отдельно по [docs/adding-plane.md](docs/adding-plane.md) — там же настройка GitLab-интеграции и вебхуков в n8n.
8. **Закрыть публичный интерфейс**: `sudo ./scripts/harden.sh` — только после того, как проверили, что через NetBird всё открывается ([docs/vpn-netbird.md](docs/vpn-netbird.md)).

## Доступ и сетевая безопасность

Платформа живёт в закрытом контуре. Вход — только через NetBird
(self-hosted, отдельный небольшой сервер под control plane). Публичных
портов у сервера платформы нет вообще: сервисы привязаны к интерфейсу
NetBird (`BIND_ADDRESS`), поверх стоит ip-фильтр Traefik, поверх — правила
ufw. Сертификаты выпускаются через DNS-01, так что входящие соединения не
нужны даже для ACME.

Установка NetBird, подключение этого сервера как peer, и способ
восстановления, если заперлись снаружи, — в
[docs/vpn-netbird.md](docs/vpn-netbird.md).

## Ресурсы сервера

| Профиль | vCPU | RAM | Диск |
|---|---|---|---|
| Минимум (core + GitLab) | 4 | 8-10 GB | 60 GB SSD |
| Рекомендуемый (+ мониторинг + автоматизация) | 6-8 | 16 GB | 150 GB SSD |
| + Plane | 10-12 | 22-24 GB | 150 GB SSD |
| + DefectDojo/Harbor поверх | 12-16 | 28-32 GB | 300+ GB SSD (registry растёт быстро) |

Подробности и пример `.gitlab-ci.yml` с публикацией находок в DefectDojo — в `docs/architecture.md`.

## Что дальше

- Terraform/Ansible для провижининга самого сервера(-ов) — добавляются, как
  только определится сервер/облако.
- Vault для секретов вместо `.env` — имеет смысл подключать при переходе
  с одного сервера на кластер.
