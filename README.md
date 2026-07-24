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

Plane (issue tracking/PM), DefectDojo (агрегация находок SAST/DAST/SCA) и
Harbor (registry с расширенным сканированием, если GitLab-registry+Trivy
окажется недостаточно) подключаются отдельно официальными установщиками —
их self-hosted дистрибутивы это 5-8 взаимозависимых сервисов каждый,
вендорить такое в свой compose и держать в синхроне с апстримом не стоит.
Инструкции: [docs/adding-plane.md](docs/adding-plane.md),
[docs/adding-defectdojo-harbor.md](docs/adding-defectdojo-harbor.md).
Roadmap по AI-агентам — в [docs/ai-agents-roadmap.md](docs/ai-agents-roadmap.md).

## Быстрый старт

Требования: Docker + Docker Compose plugin на сервере, DNS-записи (или
wildcard) на нужные поддомены `*.${BASE_DOMAIN}`, открытые 80/443 порты,
**минимум 8GB RAM только под GitLab** (см. таблицу ресурсов ниже).

```bash
cp .env.example .env
$EDITOR .env   # заполнить пароли, домен, email для Let's Encrypt

# core + GitLab — минимальный рабочий набор
./scripts/up.sh gitlab

# добавить мониторинг и автоматизацию
./scripts/up.sh monitoring automation
```

После первого запуска (GitLab поднимается 3-5 минут при первом старте):

1. `https://sso.${BASE_DOMAIN}` — создать realm/клиентов в Keycloak для остальных сервисов.
2. `https://git.${BASE_DOMAIN}` — залогиниться как `root` / `GITLAB_ROOT_PASSWORD`, создать первую группу/проект.
3. Admin Area → CI/CD → Runners → New instance runner — скопировать токен, прописать в `.env` как `GITLAB_RUNNER_TOKEN`, поднять `gitlab-runner`.
4. `https://grafana.${BASE_DOMAIN}` — датасорсы Prometheus/Loki уже прописаны автоматически.
5. `https://automation.${BASE_DOMAIN}` — настроить workflow'ы n8n под вебхуки GitLab/Plane/DefectDojo/Alertmanager.
6. Plane ставится отдельно по [docs/adding-plane.md](docs/adding-plane.md) — там же настройка GitLab-интеграции и вебхуков в n8n.

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
