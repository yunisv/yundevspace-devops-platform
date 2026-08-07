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
  → Telegram Trigger (n8n, тот же бот Alerts_TG — токен уже есть в credentials)
  → скачать voice.ogg → Whisper (локально, docker-compose.whisper.yml) → текст
  → Ollama: классифицировать намерение → JSON {action, params, reply_text}
  → Switch по action:
       - create_task      → Plane API (+ прикреплённые файлы)
       - trigger_pipeline → GitLab API (POST .../pipeline)
       - show_dojo_report → DefectDojo API → отформатировать → отправить в чат
       - unknown          → переспросить в чат
```

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

## Этап 1 (текущий): развернуть Whisper и проверить транскрипцию

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

## Этапы 2-4 (следующие)

- **Telegram Trigger в n8n** — новый nod в существующем/новом workflow,
  фильтр по `chat_id` и по факту упоминания бота, скачивание
  voice/photo/document через Bot API.
- **Ollama-роутер** — промпт на классификацию намерения в JSON.
- **show_dojo_report** → **trigger_pipeline** → **create_task** — по
  очереди, в этом порядке (от простого к сложному, Plane API ещё не
  трогали в этом проекте).

Будет дополняться по мере прохождения этапов.
