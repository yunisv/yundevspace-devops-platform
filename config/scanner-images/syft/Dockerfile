# anchore/syft — distroless (нет /bin/sh вообще, подтверждено живым
# падением "exec: sh: executable file not found", см.
# docs/ssdlc-pipeline.md). Копируем бинарь на alpine вместо
# entrypoint-воркэраунда (тут он и не помог бы) и вместо install-script
# на лету в каждой CI-джобе (медленнее, сетевая зависимость на каждый
# прогон).
#
# Путь /syft — best-effort (Anchore обычно кладёт бинарь в корень
# образа), не проверено сборкой. Диагностика при ошибке COPY:
#   docker run --rm --entrypoint sh anchore/syft:latest \
#     -c 'which syft || find / -name syft -type f 2>/dev/null'
# (может не сработать — если в исходном образе тоже нет /bin/sh,
# смотреть через docker cp с фиктивным контейнером вместо exec).
FROM anchore/syft:latest AS source

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=source /syft /usr/local/bin/syft
ENTRYPOINT []
