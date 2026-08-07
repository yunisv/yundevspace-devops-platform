# AI-агент №2: триаж находок DefectDojo (n8n + Ollama)

Первый пункт из `docs/ai-agents-roadmap.md`, реализованный в коде: LLM
(локальная, через Ollama — см. `docs/local-llm.md`) оценивает каждую новую
находку после импорта скана, пишет обоснование в Notes находки, при
необходимости поправляет severity, и для критичных случаев сразу создаёт
issue в GitLab — без блокировки пайплайна, только советует/размечает.

## Как это устроено

```
GitLab CI импортирует скан в DefectDojo (уже работает)
  → DefectDojo шлёт Notification Webhook (событие scan_added) в n8n
  → n8n запрашивает находки этого теста через API DefectDojo
  → на каждую ещё не размеченную находку — запрос к Ollama с промптом
  → ответ LLM (JSON: severity/reasoning/create_issue)
  → POST заметка в находку + PATCH severity/tags (тег llm-triaged — от
    повторного триажа при реимпорте того же теста)
  → если Critical или LLM попросил — issue в GitLab
```

Готовый workflow — `config/n8n/workflows/defectdojo-triage.json`, импорт
целиком вместо ручной сборки нод.

### Важный нюанс: webhook у DefectDojo — не «на находку»

У DefectDojo OSS нет события уровня "новая находка". Notification
Webhooks (в открытой версии — статус "experimental") оперируют событиями
уровня скана: `scan_added` ("Triggered whenever an (re-)import has been
done that created/updated/closed findings") и `scan_added_empty`.
Поэтому workflow сам вытягивает список находок конкретного теста через
`GET /api/v2/findings/?test=<id>` и фильтрует те, что уже были
протриажены раньше (тег `llm-triaged`) — иначе реимпорт того же теста
повторно гонял бы LLM по всем находкам заново.

## 1. DefectDojo: включить Notification Webhooks

В UI DefectDojo (через выпадающее меню пользователя, обычно
**Configuration → Notifications** или отдельный пункт **Webhooks** —
в разных версиях 2.x пункт меню называется чуть по-разному, искать по
слову "Webhook"):

1. Включить канал **Webhooks** для события **scan_added** (можно на
   уровне System Settings — тогда сработает для всех продуктов).
2. Добавить эндпоинт: URL — `https://automation.${BASE_DOMAIN}/webhook/defectdojo-scan-added`,
   без аутентификации (эндпоинт закрыт `internal-only@file` на уровне
   Traefik — снаружи VPN недостижим в принципе).
3. DefectDojo сразу пришлёт `ping`-событие на этот URL, чтобы проверить
   доступность — до этого шага сам workflow должен быть уже импортирован
   и активен в n8n (см. ниже), иначе ping не дойдёт и эндпоинт может
   быть помечен неактивным.

Дополнительно — создать API-токен для сервис-аккаунта, которым будет
дёргать API n8n: **User menu → API v2 Key** (или через админку —
отдельный пользователь `n8n-service` с ролью, ограниченной нужными
продуктами, чтобы не выдавать n8n токен от полного admin).

## 2. n8n: credentials

Два credential'а типа **Header Auth** (Settings → Credentials → New):

| Имя (важно — совпадает со ссылками в workflow) | Header Name | Header Value |
|---|---|---|
| `DefectDojo API` | `Authorization` | `Token <API-токен из шага 1>` |
| `GitLab API` | `PRIVATE-TOKEN` | `<Personal/Project Access Token с правами api>` |

Токен GitLab — Project Access Token с ролью Reporter+ и правом `api`,
привязанный к проекту(ам), куда должны создаваться issue.

## 3. Импорт workflow

**Workflows → Import from File** → выбрать
`config/n8n/workflows/defectdojo-triage.json`.

После импорта:

1. Открыть ноду **Get Findings**, **Add Note**, **Update Finding** —
   привязать credential `DefectDojo API` (после импорта JSON credential
   привязывается по имени не всегда автоматически — если нода показывает
   "credential not set", выбрать вручную из списка).
2. То же для **Create GitLab Issue** → credential `GitLab API`.
3. Открыть ноду **Map Product to GitLab Project**, вписать реальный ID
   проекта(ов) в `PRODUCT_TO_PROJECT` (ID проекта — на странице проекта
   в GitLab, под названием — "Project ID: 123"). Имя ключа — точное имя
   продукта в DefectDojo (Product name), не название GitLab-проекта.
4. Активировать workflow (тумблер **Active** вверху).

## 4. Проверка

Прогнать пайплайн `usta_tap` ещё раз (тот, что уже импортирует
SAST/secret-detection в DefectDojo) — реимпорт теста вызовет
`scan_added`. Проверить по цепочке:

1. **n8n → Executions** — появилось ли выполнение workflow вообще (если
   нет — DefectDojo не достучался, проверить URL вебхука в шаге 1).
2. Открыть выполнение, посмотреть вывод ноды **Get Test ID** — если
   `test_id` пустой, значит реальные имена полей в присланном payload
   отличаются от предположенных в коде ноды — поправить `test.id ??
   test.test_id ?? ...` под то, что реально пришло (видно в самом JSON
   входа этой ноды).
3. Если `test_id` подтянулся — дальше по цепочке смотреть, вернула ли
   **Get Findings** непустой список, и что ответила **Call Ollama**
   (модель уже проверена вживую — `docs/local-llm.md`).
4. В самом DefectDojo — открыть одну из находок, проверить, что в Notes
   появилась запись с обоснованием, а severity/tags обновились.
5. Если LLM сочла что-то Critical — проверить, что issue реально создался
   в GitLab с нужным продуктом → проектом.

## Известные ограничения этой первой версии

- Маппинг продукт → GitLab-проект — вручную, в коде ноды. Нормально для
  одного-двух проектов; если продуктов станет много, стоит вынести в
  отдельный lookup (например, JSON в `homepage.description`-стиле
  лейблах или отдельный n8n credential/переменную), но пока это
  избыточно.
- LLM видит только текст находки (title/description/CWE/путь к файлу) —
  не сам diff и не окружающий код. Для более точного вердикта это будет
  улучшено на этапе доп. требований ("дополнения", о которых уже
  говорили) — пока сознательно MVP.
- Режим "только советует" выдержан частично: severity/tags LLM меняет
  сама, автоматически — issue создаёт тоже сама. Явного механического
  gate'а на деплой это НЕ ставит (пайплайн не блокируется), но если
  захочется вернуть ручное подтверждение перед PATCH — это отдельная
  IF-нода перед **Update Finding**, обсуждаемо.
