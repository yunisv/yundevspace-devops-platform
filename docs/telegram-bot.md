# Telegram-бот: голосовые команды (упоминание бота в рабочем чате)

Следующий AI-агент сверх `docs/ai-agents-roadmap.md`: упоминаешь бота
`Alerts_TG` в рабочем чате, прикрепляешь голосовое (+ опционально фото/
документы) — бот транскрибирует голос, распознаёт намерение через
локальную LLM и выполняет одно из действий: создать задачу в Plane,
поднять пайплайн в GitLab, показать отчёт из DefectDojo.

Собирается поэтапно, с проверкой каждого шага на реальном сервере —
слишком много новых интеграций сразу (Telegram inbound, Whisper, Plane
API), чтобы делать это одним workflow вслепую.

## Архитектура

```
Telegram (voice/photo/document, упоминание бота в рабочем чате)
  → n8n сам стучится к Telegram API раз в 30 сек (long polling, НЕ webhook)
  → скачать voice.ogg → Whisper (локально, docker-compose.whisper.yml) → текст
  → Ollama: классифицировать намерение → JSON {action, params, reply_text}
  → Switch по action:
       - create_task      → Plane API (+ прикреплённые файлы)
       - trigger_pipeline → GitLab API (POST .../pipeline)
       - show_dojo_report → DefectDojo API → отформатировать → отправить в чат
       - unknown          → переспросить в чат
```

**Важно: не через нативный n8n Telegram Trigger.** Эта нода работает
через webhook — Telegram должен сам достучаться до
`automation.${BASE_DOMAIN}` со своих публичных серверов, а у нас весь
входящий трафик снаружи закрыт (Hetzner Firewall deny-all inbound,
Traefik слушает только NetBird IP) — пробивать под это дырку в файрволе
не стали. Вместо этого — **long polling**: отдельный workflow
(`config/n8n/workflows/telegram-voice-commands.json`) сам, по
расписанию, стучится НАРУЖУ к `getUpdates` (это разрешено, входящих
портов не требует). Смещение (`offset`, чтобы не обрабатывать одно и то
же сообщение дважды) хранится в n8n workflow static data.

Privacy mode бота (включён по умолчанию) сам ограничивает, что вообще
долетает до `getUpdates` в групповом чате — только команды/упоминания/
реплаи боту, обычную переписку Telegram даже не отдаёт. Фильтр по
`chat_id` в workflow — просто подстраховка на случай, если бота добавят
ещё куда-то.

**Доступ**: ограничено конкретным `chat_id` — тем же рабочим чатом, куда
уже льются алерты из Alertmanager (см. workflow `Alerts_TG`). Сообщения
из любых других чатов бот игнорирует, даже если его туда добавят —
проверка `chat_id` первым делом в workflow, до любой другой логики.

**Голос остаётся на сервере**: транскрипция через локальный Whisper
(`faster-whisper`, модель `small`, язык `ru` по умолчанию), не через
внешний STT API — тот же принцип, что и с LLM в `docs/local-llm.md`.

## Ресурсы: Ollama + Whisper на одном сервере

Whisper — ещё один CPU-тяжёлый сервис на том же хосте, где уже 12 из 16
ядер отданы Ollama. Голосовая команда теоретически может прилететь, пока
идёт триаж находки DefectDojo (`docs/ai-agent-defectdojo-triage.md`) —
оба сервиса не должны иметь возможность вместе съесть всё до последнего
ядра, иначе просядут GitLab/DefectDojo.

**Изменить в `.env` на сервере**:
```bash
OLLAMA_CPU_LIMIT=8   # было 12
WHISPER_CPU_LIMIT=4
WHISPER_MEM_LIMIT=4g
WHISPER_MODEL=small
WHISPER_LANG=ru
```

12/16 ядер под AI-сервисы суммарно, 4 остаются на остальной стек.

## Этап 1 (готово): развернуть Whisper и проверить транскрипцию

```bash
docker compose -f docker-compose.yml -f docker-compose.gitlab.yml \
  -f docker-compose.monitoring.yml -f docker-compose.automation.yml \
  -f docker-compose.dashboard.yml -f docker-compose.ollama.yml \
  -f docker-compose.whisper.yml --profile runner up -d --force-recreate ollama whisper
```

(`--force-recreate ollama` — чтобы подхватил новый `OLLAMA_CPU_LIMIT=8`.)

Первый старт скачает модель `small` (сотни МБ) — недолго. Сервис слушает
9000 внутри контейнера (`/asr` — приём файла, `/docs` — Swagger UI), но
порт наружу сознательно не пробрасывается (та же логика, что с Ollama в
`docs/local-llm.md`) — образ не основан на Alpine, `curl`/`wget` внутри
него может не быть, поэтому проще всего дать контейнеру IP на
`devops_edge` и постучаться с самого хоста (он и так в этой сети через
Traefik-алиасы) через сервисное DNS-имя контейнера:

```bash
docker inspect devops-platform-whisper-1 --format '{{.NetworkSettings.Networks.devops_edge.IPAddress}}'
```

Скачай с телефона любое своё голосовое сообщение из Telegram (перешли
себе в Saved Messages → в веб-версии Telegram есть "Скачать"), закинь на
сервер (`scp test.ogg user@server:~/`) и прогони, подставив IP из
команды выше:

```bash
curl -s -F "audio_file=@test.ogg" \
  "http://<IP-контейнера>:9000/asr?output=text&language=ru"
```

Должен вернуться распознанный текст. Если модель ошибается на русском —
можно попробовать `WHISPER_MODEL=medium` (точнее, но медленнее и тяжелее
по памяти — пересчитать `WHISPER_MEM_LIMIT`).

## Этап 2 (текущий): long polling + транскрипция голосового + эхо-ответ

`config/n8n/workflows/telegram-voice-commands.json` — отдельный workflow
(не трогает `Alerts_TG`, тот же бот): **Every 30s** → **Get Offset**
(static data) → **Get Updates** (long poll, timeout 25с) → **Extract
Voice Messages** (фильтр по `chat_id` + наличию `voice`, обновление
offset) → **Get File Path** → **Download Voice** → **Whisper
Transcribe** → **Reply in Telegram** (эхо: "🎙 Распознано: ...").

Это ещё не финальная версия — просто проверка, что вся цепочка
polling → скачивание файла → Whisper → ответ в чат реально работает,
прежде чем добавлять Ollama-роутер и сами действия.

**Импорт**: Workflows → Import from File →
`config/n8n/workflows/telegram-voice-commands.json`, активировать
(тумблер Active).

**Две ноды, скорее всего потребуют ручной проверки** (бинарные данные
в n8n сложнее гарантировать вслепую, чем обычный JSON, который мы
гоняли в триаже находок):
- **Download Voice** — должна возвращать файл как бинарные данные, не
  как текст. Открой ноду → **Options → Response → Response Format**,
  должно быть выставлено **File**. Если ошибка при выполнении — первым
  делом проверить это поле.
- **Whisper Transcribe** — отправляет бинарник как `multipart/form-data`
  с полем `audio_file`. Открой ноду → **Body Content Type** должен быть
  **Form-Data (Multipart)**, и там параметр типа **n8n Binary File**
  с именем `audio_file`, ссылающийся на бинарные данные из предыдущей
  ноды (обычно поле называется `data`).

**Проверка**: отправь голосовое с упоминанием бота в рабочий чат, жди
до ~30 сек (интервал polling) — бот должен ответить транскрипцией.
Если тишина — смотреть **n8n → Executions**, там будет видно, на какой
ноде остановилось (или что `Get Updates` вообще не находит новых
сообщений — тогда проверить `chat_id`/что бот точно состоит в чате).

## Этапы 3-4 (следующие)

- **Ollama-роутер** — промпт на классификацию намерения в JSON,
  вставляется между Whisper Transcribe и Reply (вместо эхо-ответа).
- **show_dojo_report** → **trigger_pipeline** → **create_task** — по
  очереди, в этом порядке (от простого к сложному, Plane API ещё не
  трогали в этом проекте).

Будет дополняться по мере прохождения этапов.
