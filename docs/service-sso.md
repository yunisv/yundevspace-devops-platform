# Единый вход в GitLab / Grafana / n8n через Keycloak

`docs/dashboard-sso.md` описывает SSO для стартовой страницы через
`oauth2-proxy` — это отдельный механизм (forwardAuth-гейт перед сервисом,
у которого нет собственного OIDC). GitLab и Grafana умеют OIDC нативно, им
`oauth2-proxy` не нужен — они сами становятся OIDC-клиентами Keycloak.
n8n Community своего SSO не имеет вообще (это Enterprise-фича), поэтому
для него используется сторонний bolt-on (`n8n-oidc`, external hooks) — см.
раздел про n8n ниже, там же и его реальные риски.

Все подключаются к тому же realm `devops`, что уже создан для
дашборда — токены Keycloak-сессии не расшариваются между сервисами
автоматически (не единая cookie, как у `oauth2-proxy`-сервисов), но
человеку достаточно один раз ввести пароль от Keycloak при входе в каждый
сервис отдельно, вместо отдельных паролей для каждого.

`2btask` (issue tracking/PM, замена Plane — `docs/adding-2btask.md`)
подключается тем же способом: свой OIDC-код (`server/app/services/sso.py`),
просто ещё один клиент в этом же realm.

## 1. Создать клиенты в Keycloak

`https://sso.${BASE_DOMAIN}` → realm **devops** → **Clients** → **Create
client**, по одному разу на каждый сервис с этими настройками (Client
authentication: **On** — иначе не будет вкладки Credentials с секретом):

| Client ID | Valid redirect URIs | Web origins |
|---|---|---|
| `gitlab` | `https://git.${BASE_DOMAIN}/users/auth/openid_connect/callback` | `https://git.${BASE_DOMAIN}` |
| `grafana` | `https://grafana.${BASE_DOMAIN}/login/generic_oauth` | `https://grafana.${BASE_DOMAIN}` |
| `n8n` | `https://automation.${BASE_DOMAIN}/auth/oidc/callback` | `https://automation.${BASE_DOMAIN}` |
| `2btask` | `https://pm.${BASE_DOMAIN}/auth/callback` | `https://pm.${BASE_DOMAIN}` |

После сохранения каждого — вкладка **Credentials** → скопировать **Client
Secret**.

## 2. Прописать секреты в `.env`

```bash
GITLAB_OIDC_CLIENT_ID=gitlab
GITLAB_OIDC_CLIENT_SECRET=<секрет из Credentials>

GRAFANA_OIDC_CLIENT_ID=grafana
GRAFANA_OIDC_CLIENT_SECRET=<секрет из Credentials>

N8N_OIDC_CLIENT_ID=n8n
N8N_OIDC_CLIENT_SECRET=<секрет из Credentials>
```

`2btask` — секреты идут не в `.env` этого репозитория, а в
`.env` самого 2btask на сервере (`SSO_CLIENT_ID`/`SSO_CLIENT_SECRET`/
`SSO_ISSUER_URL`/`SSO_REDIRECT_URI`) — см. `docs/adding-2btask.md`.

## 3. Поднять

```bash
docker compose -f docker-compose.yml -f docker-compose.gitlab.yml \
  -f docker-compose.monitoring.yml -f docker-compose.automation.yml \
  -f docker-compose.dashboard.yml --profile runner up -d
```

Пересоздадутся `gitlab`, `grafana`, `n8n` — секунда-две простоя у каждого,
остальное не тронется.

## Что где ожидать

- **GitLab**: на странице логина (`git.${BASE_DOMAIN}/users/sign_in`)
  появится кнопка **Keycloak**. Локальный `root`/пароль продолжает
  работать как есть — `omniauth_allow_single_sign_on` только добавляет
  Keycloak как альтернативу, не отключает обычный вход.
- **Grafana**: на странице логина появится кнопка **Sign in with
  Keycloak**. `admin`/`GRAFANA_ADMIN_PASSWORD` остаётся рабочим локальным
  запасным входом.
- **n8n**: форма логина заменяется на кнопку **Sign in with SSO** (это
  делает JS-скрипт из `hooks.js`, подставляемый через
  `EXTERNAL_FRONTEND_HOOKS_URLS`). Чтобы зайти обычным email/паролем
  (например, самим owner-аккаунтом, если он был создан раньше) — добавить
  `?showLogin=true` к адресу.
- **2btask**: кнопка **Войти через Keycloak** на форме входа
  появляется, только если `SSO_ENABLED=true` и остальные `SSO_*`
  заданы (`GET /api/auth/sso/status`). Пароль остаётся рабочим всегда —
  SSO дополняет вход, не заменяет. Вход по Keycloak находит уже
  существующего активного сотрудника по email и не заводит нового —
  доступ по-прежнему выдаёт администратор через «Сотрудники».

## n8n: что именно происходит и в чём риск

n8n Community не имеет собственного OIDC — платный Enterprise-тариф
(от $400/мес) единственный официальный путь. Вместо этого используется
[`n8n-oidc`](https://github.com/cweagans/n8n-oidc) — сторонний скрипт на
чистом Node.js (без внешних зависимостей), подключаемый через встроенный
в n8n механизм `external hooks` (`config/n8n/hooks.js` в этом репозитории,
скачан и проверен построчно перед добавлением).

Что он делает: регистрирует `/auth/oidc/login` и `/auth/oidc/callback`,
проводит стандартный Authorization Code flow со state/nonce защитой от
CSRF, находит пользователя n8n по email или создаёт нового
(`global:member`, если owner уже существует — не перезаписывает
владельца), выписывает n8n-шную auth-cookie через внутренний `JwtService`.

**Реальный риск**: скрипт обращается к недокументированным внутренним
путям n8n (`@n8n/di` DI-контейнер, `dist/services/jwt.service.js`,
`dbCollections` напрямую) — это не публичный API, а деталь реализации
конкретной версии. `@n8n/di` появился в районе n8n 1.70-1.75 (в 1.60.1,
на которой раньше стоял этот стек, его ещё не было — версия образа
поднята до **1.80.0**, где наличие обоих компонентов проверено напрямую
против исходников n8n перед пином). При будущем обновлении образа n8n
на более новую версию нужно **сначала проверить**, что вход через
Keycloak по-прежнему работает, прежде чем полагаться на него — внутренние
пути могут измениться без предупреждения, в отличие от GitLab/Grafana,
где это поддерживаемая, документированная функциональность.
