# hadolint/hadolint:latest (не -debian, тот образ мы и так используем
# напрямую в container-scan.yml с entrypoint: [""] — уже рабочий
# вариант) — этот Dockerfile для единообразия со всеми остальными
# образами в этом registry (все через свою сборку, без исключений).
# Путь /bin/hadolint — best-effort, не проверено сборкой. Диагностика:
#   docker run --rm --entrypoint sh hadolint/hadolint:latest-debian \
#     -c 'which hadolint'
# (у -debian есть shell, можно так проверить путь и для обычного тега,
# если предположить, что он тот же).
FROM hadolint/hadolint:latest AS source

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=source /bin/hadolint /usr/local/bin/hadolint
ENTRYPOINT []
