# Свой Docker Registry для образов сканеров SSDLC

Проблема, которую это решает: несколько образов сканеров, используемых
в `config/gitlab-ci/pipelines/`, либо ломают GitLab CI из-за
собственного ENTRYPOINT (gitleaks, trufflehog — фиксится
`entrypoint: [""]`), либо вообще distroless — без `/bin/sh` внутри
(syft, grype, osv-scanner — `entrypoint: [""]` тут не спасает, у нас
временно образы ставят бинарь через `curl | sh` install-script прямо в
CI-джобе, см. `docs/ssdlc-pipeline.md`). Оба класса проблем разбирали
живьём на реальном тестировании.

Решение — не использовать образы вендоров напрямую, а **пересобрать
свои**: только бинарь инструмента, скопированный на обычный `alpine` с
нормальным shell. Никаких воркэраундов в самих CI-джобах сканирования
не нужно, и не нужно ничего доустанавливать на лету (быстрее — не
тянуть install-script и пакеты каждый прогон).

## Что уже сделано (в этом репозитории)

`config/scanner-images/` — Dockerfile под каждый образ
(`gitleaks/`, `trufflehog/`, `syft/`, `grype/`, `osv-scanner/`,
`hadolint/`) + `.gitlab-ci.yml` с Kaniko-джобой на каждый (не
`docker build` — раннер без privileged, DinD не поднять, Kaniko же
не требует privileged вообще).

**Важно — честно предупреждаю**: точные пути к бинарям ВНУТРИ
оригинальных образов (`/usr/bin/gitleaks`, `/syft`, `/grype`,
`/osv-scanner`, `/bin/hadolint`) я указал по best-effort знанию, **не
проверял живой сборкой** — я не могу собрать Docker-образ из этой
сессии. Если `docker build`/Kaniko упадёт на шаге `COPY --from=... :
no such file or directory` — в каждом `Dockerfile` в комментарии
написано, как найти реальный путь (через `docker run --entrypoint sh`
для образов с shell внутри, или `docker create` + `docker cp` для
полностью distroless, где `exec` не работает).

## Настройка (один раз)

1. Создать проект `devops/scanner-images` в GitLab, запушить туда
   содержимое `config/scanner-images/`.
2. У проекта уже есть встроенный Container Registry (часть GitLab CE,
   уже включён в `docker-compose.gitlab.yml` — `registry.${BASE_DOMAIN}`
   через Traefik) — ничего дополнительно настраивать не нужно,
   `$CI_REGISTRY_IMAGE` резолвится сам в
   `registry.devops.2be.az/devops/scanner-images`.
3. Build → Pipelines → New pipeline (или просто push) → в списке джоб
   (все `when: manual`) запустить `build-gitleaks` и посмотреть лог —
   если упадёт на `COPY`, поправить путь в соответствующем
   `Dockerfile` по инструкции из комментария, перезалить, повторить.
   Дальше так же по одной для остальных пяти.
4. Убедиться, что образ реально работает — например:
   ```bash
   docker run --rm registry.devops.2be.az/devops/scanner-images/gitleaks:latest gitleaks version
   ```

## После того как все образы собраны и проверены — переключить пайплайны

**Пока не делаю это автоматически** — если переключить
`config/gitlab-ci/pipelines/*.yml` на новые образы ДО того, как они
реально собраны и запушены в registry, текущий рабочий пайплайн
сломается (образ не найдётся). Сначала собери и провери все 6, потом
скажи — заменю:

- `secret-scan.yml`: `zricethezav/gitleaks:latest` →
  `$CI_REGISTRY/devops/scanner-images/gitleaks:latest`,
  `trufflesecurity/trufflehog:latest` → `.../trufflehog:latest`,
  убрать `entrypoint: [""]` у обоих (не нужен).
- `sbom.yml`: `anchore/syft:latest` → `.../syft:latest`.
- `sca.yml` (`sca-grype`): убрать `alpine:3.20` +
  `before_script: apk add curl && install.sh`, образ →
  `.../grype:latest`.
- `sca.yml` (`sca-osv-scanner`): убрать `alpine:3.20` +
  `before_script`, образ → `.../osv-scanner:latest`.
- `container-scan.yml` (`container-scan-grype`): та же замена, что и
  `sca-grype`.
- `container-scan.yml` (`container-scan-hadolint`): образ →
  `.../hadolint:latest`, убрать `entrypoint: [""]`.

## Обслуживание

Образы не обновляются сами при выходе новых версий инструментов —
разово собрал и забыл, со временем версии "протухнут". Варианты:
- Периодически руками перезапускать `when: manual` джобы.
- Настроить **Pipeline Schedule** в GitLab UI (Build → Pipeline
  schedules) на этом проекте, например раз в неделю — тогда джобы
  надо будет убрать из `when: manual` (или сделать отдельные
  `rules: - if: '$CI_PIPELINE_SOURCE == "schedule"'` копии).
