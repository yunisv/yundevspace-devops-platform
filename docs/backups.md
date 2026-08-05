# Бэкапы

## Что бэкапится

`./scripts/backup.sh` собирает один архив `devops-platform-backup-<дата>.tar.gz`:

| Что | Как | Что НЕ включено |
|---|---|---|
| GitLab (репозитории, БД, wiki, CI-конфиг) | `gitlab-backup create` внутри контейнера — штатный механизм GitLab, консистентный снимок | По умолчанию `SKIP=artifacts,registry` — джобовые артефакты и образы Container Registry пропускаются (самое тяжёлое и наименее критичное; поправьте флаг в `scripts/backup.sh`, если нужны) |
| `gitlab-secrets.json`, `gitlab.rb` | копия из контейнера | без этого файла бэкап GitLab **невозможно** восстановить — в нём ключи шифрования CI-переменных |
| База Keycloak | `pg_dump` | — |
| `secrets/dashboard.htpasswd`, TLS-состояние Traefik (`acme.json`) | копии файлов/тома | — |
| `.env` | копия | — |

Plane / DefectDojo / Harbor, если поставите — бэкапятся отдельно, у каждого свой встроенный механизм (это официальные установщики вне этого репозитория).

## Куда это писать

```bash
./scripts/backup.sh                    # ./backups/
./scripts/backup.sh /mnt/external       # своя директория
```

**Это не бэкап, пока архив не покинул сервер.** Простейший вариант — cron с rsync на другую машину или Hetzner Storage Box:

```bash
# /etc/cron.d/devops-platform-backup
0 3 * * * root cd /root/devops-platform && ./scripts/backup.sh >> /var/log/devops-platform-backup.log 2>&1
15 3 * * * root rsync -az /root/devops-platform/backups/ user@backup-host:/backups/devops-platform/
```

Локально скрипт держит только последние 7 архивов (`find -mtime +7 -delete`) — расчёт на то, что настоящая копия уже унесена вторым cron-заданием.

## Восстановление

### GitLab

На новом/чистом сервере — сначала поднять сам стек (`./scripts/install.sh`), **до первого логина**:

```bash
tar -xzf devops-platform-backup-<дата>.tar.gz -C /tmp/restore

# секреты — на место, ДО restore
docker compose cp /tmp/restore/gitlab-secrets.json gitlab:/etc/gitlab/gitlab-secrets.json
docker compose cp /tmp/restore/gitlab.rb gitlab:/etc/gitlab/gitlab.rb
docker compose restart gitlab

# сам бэкап — в директорию, откуда GitLab восстанавливает
docker compose cp /tmp/restore/gitlab_backup.tar gitlab:/var/opt/gitlab/backups/
docker compose exec gitlab gitlab-backup restore BACKUP=<префикс_имени_файла_без_gitlab_backup.tar>
docker compose restart gitlab
```

Официальная документация GitLab по restore (там же — про несовпадение версий GitLab между бэкапом и текущей установкой, это важно свериться):
https://docs.gitlab.com/ee/administration/backup_restore/

### Keycloak

```bash
cat /tmp/restore/keycloak-db.sql | docker compose exec -T -e PGPASSWORD=<KEYCLOAK_DB_PASSWORD> keycloak-db psql -U keycloak keycloak
docker compose restart keycloak
```

### Traefik (TLS)

```bash
docker compose cp /tmp/restore/acme.json traefik:/acme/acme.json
docker compose restart traefik
```
Необязательно — Traefik просто перевыпустит сертификат заново через DNS-01, если это не восстанавливать. Полезно, только если хотите сэкономить один цикл выпуска у Let's Encrypt.

### `.env` / `secrets/`

Просто скопировать поверх перед первым запуском `./scripts/install.sh` на новом сервере — тогда скрипт не будет генерировать новые пароли, а использует старые (важно, если восстанавливаете тот же GitLab — его `initial_root_password` в первой `GITLAB_OMNIBUS_CONFIG` реально влияет только при самом первом запуске, дальнейшие логины идут по паролю, который вы сами меняли в UI).

## Чего в этом плане нет (сознательно)

- **Мониторинг (Prometheus/Loki)** не бэкапится — метрики и логи считаются одноразовыми, восстанавливать историю графиков смысла нет.
- **Docker-образы** — вытягиваются заново из реестров при разворачивании, бэкапить незачем.
