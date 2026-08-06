# Стартовая страница (Homepage) и SSO через Keycloak

`https://dash.${BASE_DOMAIN}` — единая точка входа: плитки всех сервисов
платформы с живыми статусами, за логином Keycloak.

Сервисы **не перечисляются вручную**: Homepage читает docker-лейблы
`homepage.*` (они уже проставлены рядом с Traefik-лейблами в каждом
`docker-compose.*.yml`), поэтому новый сервис появляется на странице сам.
Вручную в `config/homepage/services.yaml` добавляются только те штуки,
что ставятся своими установщиками — Plane, DefectDojo, Harbor.

Почему oauth2-proxy, а не `thomseddon/traefik-forward-auth`, который чаще
встречается в гайдах: у последнего нет коммитов с 2021 года.

## Порядок настройки

Слой `dashboard` **не поднимается по умолчанию** — oauth2-proxy не
стартует, пока в Keycloak нет realm-а и клиента. Сначала настраиваем
Keycloak, потом поднимаем слой.

### 1. Realm в Keycloak

`https://sso.${BASE_DOMAIN}` → войти под `KEYCLOAK_ADMIN` / паролем из
`.env` → Create realm → имя `devops` (должно совпадать с `KEYCLOAK_REALM`
в `.env`).

### 2. Клиент для oauth2-proxy

В realm-е `devops`: Clients → Create client.

| Поле | Значение |
|---|---|
| Client ID | `oauth2-proxy` (совпадает с `OAUTH2_PROXY_CLIENT_ID`) |
| Client authentication | **On** (confidential-клиент, иначе не будет secret-а) |
| Valid redirect URIs | `https://dash.${BASE_DOMAIN}/oauth2/callback` |
| Web origins | `https://dash.${BASE_DOMAIN}` |

После сохранения: вкладка **Credentials** → скопировать Client Secret →
вписать в `.env` как `OAUTH2_PROXY_CLIENT_SECRET`.

`OAUTH2_PROXY_COOKIE_SECRET` уже сгенерирован `install.sh` (oauth2-proxy
принимает только 16/24/32 байта в base64 — обычный hex не подойдёт).

### 3. Пользователи

Users → Add user → вкладка Credentials → задать пароль. Либо подключить
LDAP/AD федерацию, если она есть в компании.

### 4. Поднять слой

```bash
./scripts/up.sh dashboard
```

DNS-запись `dash.${BASE_DOMAIN}` должна резолвиться на сервер — иначе
Let's Encrypt не выдаст сертификат.

## Как закрыть этим же логином другие сервисы

oauth2-proxy публикует две Traefik-middleware, которые нужно вешать
**вместе и в этом порядке** — `sso-errors@docker`, потом `sso@docker`.
Одного `sso@docker` (`forwardAuth`) недостаточно: сам по себе он на
неавторизованный запрос просто отдаёт голый `401 Unauthorized` от
`/oauth2/auth` (эндпоинт только для проверки, без редиректа никуда) —
`sso-errors` перехватывает этот 401 и уводит на страницу логина:

```yaml
labels:
  - traefik.http.routers.prometheus.middlewares=sso-errors@docker,sso@docker
```

Полезно для Prometheus и Alertmanager: у них **нет собственной
аутентификации вообще**, и по умолчанию в этом стеке они доступны всем,
кто знает адрес. GitLab/Grafana/n8n свой логин имеют, их можно оставить
как есть (или тоже завести в SSO — но настраивать это лучше внутри самих
сервисов, через их OIDC-интеграцию, чтобы не терять их роли и права).

Cookie выписывается на `.${BASE_DOMAIN}`, поэтому один вход работает на
всех поддоменах платформы.

## Виджеты с живыми данными

Плитка может показывать не только ссылку, но и состояние сервиса
(пайплайны GitLab, активные алерты Grafana). Для этого нужен API-токен:

1. Создать токен в самом сервисе (в GitLab — Personal/Project Access Token с правом `read_api`).
2. Положить его в `.env` как `HOMEPAGE_VAR_GITLAB_TOKEN=...`.
3. Пробросить переменную в контейнер homepage (`environment:` в `docker-compose.dashboard.yml`).
4. Раскомментировать блок с виджетом в `config/homepage/services.yaml`.

Токены подставляются на сервере и в браузер не попадают.

## Доступ к docker.sock

Homepage монтирует `/var/run/docker.sock:ro` — так работает
auto-discovery. Права read-only, но это всё ещё полный доступ на чтение
ко всему Docker API (включая переменные окружения других контейнеров).
Если это слишком широко — поставьте `docker-socket-proxy` и укажите его
адрес в `config/homepage/docker.yaml` вместо сокета.
