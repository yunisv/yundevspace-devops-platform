# Оригинальный zricethezav/gitleaks — ENTRYPOINT сам бинарь, ломает
# script: в GitLab CI (см. docs/ssdlc-pipeline.md, "unknown command sh").
# Копируем ТОЛЬКО бинарь на обычный alpine с нормальным shell — чище,
# чем entrypoint: [""] воркэраунд, и не нужно ничего ставить на лету в
# CI-джобе.
#
# Путь /usr/bin/gitleaks — best-effort (по официальному Dockerfile
# gitleaks на момент написания), не проверено сборкой в этой сессии.
# Если `docker build` упадёт на COPY с "no such file or directory" —
# найти реальный путь:
#   docker run --rm --entrypoint sh zricethezav/gitleaks:latest \
#     -c 'which gitleaks || find / -name gitleaks -type f 2>/dev/null'
# и поправить путь ниже.
FROM zricethezav/gitleaks:latest AS source

# git — обязателен: `gitleaks detect` (без --no-git) сканирует через
# git-историю и вызывает системный git-бинарь напрямую (не libgit2),
# упало живьём в CI с "could not create Git cmd: exec: git: executable
# file not found in $PATH" — у вендорского образа git был, в голом
# alpine его нет по умолчанию.
FROM alpine:3.20
RUN apk add --no-cache ca-certificates git
COPY --from=source /usr/bin/gitleaks /usr/local/bin/gitleaks
ENTRYPOINT []
