# Тот же паттерн и та же причина, что и syft/Dockerfile — Anchore,
# тоже distroless. Путь /grype — best-effort, не проверено сборкой.
# Диагностика при ошибке COPY: docker cp с фиктивным контейнером
# (docker create + docker cp), раз exec в сам образ может не работать
# без shell:
#   docker create --name tmp anchore/grype:latest
#   docker cp tmp:/grype ./grype-check   # если путь верный, файл появится
#   docker rm tmp
FROM anchore/grype:latest AS source

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=source /grype /usr/local/bin/grype
ENTRYPOINT []
