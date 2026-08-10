# Тот же паттерн, что и gitleaks/Dockerfile — см. комментарий там.
# Путь /usr/bin/trufflehog — best-effort, не проверено сборкой.
# Диагностика при ошибке COPY:
#   docker run --rm --entrypoint sh trufflesecurity/trufflehog:latest \
#     -c 'which trufflehog || find / -name trufflehog -type f 2>/dev/null'
FROM trufflesecurity/trufflehog:latest AS source

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=source /usr/bin/trufflehog /usr/local/bin/trufflehog
ENTRYPOINT []
