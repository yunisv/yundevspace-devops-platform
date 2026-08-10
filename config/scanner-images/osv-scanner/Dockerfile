# ghcr.io/google/osv-scanner — тоже distroless (тот же класс проблемы,
# что и syft/grype). Путь /osv-scanner — best-effort, не проверено
# сборкой. Диагностика при ошибке COPY (тем же способом, что в
# grype/Dockerfile — docker create + docker cp, раз exec в образ без
# shell не работает):
#   docker create --name tmp ghcr.io/google/osv-scanner:latest
#   docker cp tmp:/osv-scanner ./osv-scanner-check
#   docker rm tmp
FROM ghcr.io/google/osv-scanner:latest AS source

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=source /osv-scanner /usr/local/bin/osv-scanner
ENTRYPOINT []
