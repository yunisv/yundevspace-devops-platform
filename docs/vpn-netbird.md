# Закрытый доступ: NetBird + блокировка портов

Цель — к серверу нельзя обратиться по IP, сервисы платформы недоступны из
интернета, вход только через VPN с корпоративным аккаунтом.

## Что остаётся публичным и почему

Полностью закрыть всё нельзя: человек логинится в VPN **до** того, как
попадает в VPN, поэтому точка входа обязана быть снаружи.

| Порт | Кому | Зачем |
|---|---|---|
| 443/tcp | всем | вход в NetBird (`netbird.`) и Keycloak (`sso.`). Остальные хосты на этом же порту закрыты ip-фильтром Traefik (`internal-only`), то есть отвечают только пирам VPN |
| 3478/udp | всем | STUN/TURN NetBird |
| 49152-65535/udp | всем | relay-диапазон TURN |
| 22/tcp, 80/tcp, 2222/tcp | **закрыты** | SSH, HTTP и git-по-SSH доступны только из VPN |

Порт 80 закрыт потому, что сертификаты выпускаются через DNS-01 у Hetzner
(TXT-запись), а не через HTTP-01. Побочный плюс: один wildcard-сертификат
на `*.${BASE_DOMAIN}` вместо отдельного на каждый поддомен — имена
поддоменов перестают попадать в публичные Certificate Transparency логи,
по которым инфраструктуру иначе можно просто перечислить.

## Порядок

Последовательность важна: **сначала VPN, потом блокировка портов.**
`harden.sh` закрывает SSH, и если VPN на тот момент не работает, попасть на
сервер можно будет только через консоль Hetzner.

### 1. DNS

A-записи на сервер: `netbird` и `sso` — обязательно (публичные), плюс
остальные поддомены платформы. Проще всего wildcard `*.${BASE_DOMAIN}`.

### 2. Установка NetBird

Ставится своим официальным установщиком — как Plane и DefectDojo, по той же
причине: это несколько сервисов (management, signal, dashboard, coturn) со
своей генерацией конфигов, вендорить их к себе смысла нет.

```bash
export NETBIRD_DOMAIN=netbird.${BASE_DOMAIN}
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started-with-zitadel.sh | bash
```

Этот скрипт по умолчанию поднимает свой IdP (Zitadel). Так как Keycloak у
нас уже есть, лучше подключить его — см. раздел ниже и
[Advanced guide](https://docs.netbird.io/selfhosted/selfhosted-guide) в
документации NetBird.

### 3. Keycloak как IdP для NetBird

В realm `devops` (том же, что для dashboard):

1. Clients → Create client → ID `netbird`, Client authentication **On**.
2. Valid redirect URIs: `https://netbird.${BASE_DOMAIN}/*`
3. Отдельный клиент для Management API с service account — по инструкции NetBird.
4. Client Secret из вкладки Credentials → в конфиг NetBird (`management.json` / `.env` установщика).

Итог: доступ к VPN выдаётся и **отзывается** там же, где остальные
доступы — в Keycloak. Уволили человека, отключили в Keycloak — он потерял и
VPN, и всю платформу разом.

### 4. Проверка

Поставить клиент NetBird на свою машину, залогиниться, подключиться и
убедиться, что открывается, например, `https://git.${BASE_DOMAIN}` и
работает `ssh -p 2222`. **Не переходите к шагу 5, пока это не работает.**

### 5. Закрыть порты

```bash
sudo ./scripts/harden.sh --dry-run   # посмотреть, что будет применено
sudo ./scripts/harden.sh             # применить
```

Скрипт спросит подтверждение и потребует ответить `yes`.

## Если заперлись снаружи

Консоль Hetzner Cloud → нужный сервер → Console (это VNC, работает в обход
сети), затем:

```bash
ufw disable
```

## Что проверить после блокировки

```bash
# с машины ВНЕ VPN — всё должно отваливаться по таймауту:
curl -sS --max-time 5 https://git.${BASE_DOMAIN}     # ожидаем 403 или таймаут
nc -z -w5 <server-ip> 22                              # ожидаем закрыто

# sso и netbird — наоборот, должны отвечать:
curl -sS -o /dev/null -w '%{http_code}\n' https://sso.${BASE_DOMAIN}
```

## Ограничение, о котором стоит помнить

Раз `automation.` (n8n) закрыт ip-фильтром, вебхуки от **внешних** SaaS
(например, github.com) до него не дойдут. Внутри платформы всё работает —
GitLab, Plane, DefectDojo и Alertmanager шлют вебхуки из той же сети. Если
внешний вебхук всё же понадобится, снимите `internal-only` с конкретного
роутера и закройте его чем-то другим (подпись вебхука, отдельный путь).
