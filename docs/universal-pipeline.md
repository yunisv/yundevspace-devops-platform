# Универсальный пайплайн: автоопределение стека + downstream pipelines

Роутер, который по маркер-файлам в репозитории определяет стек проекта
и запускает соответствующий **официальный** шаблон GitLab (тот же, что
виден в `GET /api/v4/templates/gitlab_ci_ymls` на самом инстансе) как
child pipeline — без ручного `.gitlab-ci.yml` под каждый проект.

Не путать с [Auto DevOps](https://docs.gitlab.com/ee/topics/autodevops/)
(тоже автоопределяет стек, но через buildpacks — чёрный ящик, зашитая
логика сборки) — здесь вместо этого явно триггерятся конкретные
официальные шаблоны GitLab, которые можно посмотреть заранее и понимать,
что реально выполняется.

## Почему не что-то стороннее/платное

Разобрано подробно в чате при создании — коротко: обнаружение стека
(via buildpacks/Nixpacks) и запуск downstream pipelines — обе части уже
бесплатно есть в self-hosted GitLab CE, платные инструменты (Buildkite,
Harness CI, GitLab Duo) не добавляют тут ничего критичного при таком
масштабе. Сами шаблоны сборки под конкретный стек — тоже часть
дистрибутива GitLab (не сторонний open-source проект), поддерживаются
GitLab, ничего не тянется с внешних серверов при запуске пайплайна.

## Настройка (один раз)

1. Создать отдельный проект в GitLab для общих CI-шаблонов, например
   `devops/ci-templates` (или в существующей группе).
2. Запушить туда `config/gitlab-ci/universal-pipeline.yml` из этого
   репозитория (файл лежит здесь для версионирования вместе с остальной
   платформой — сам он используется не отсюда, а из того нового проекта).
3. Настроить автоприменение (см. ниже) — тогда шаг «добавить include в
   `.gitlab-ci.yml`» не нужен вообще, ни для новых проектов, ни для уже
   существующих.

Без автоприменения (раздел ниже) пришлось бы вручную добавлять в каждый
проект:
```yaml
include:
  - project: 'devops/ci-templates'
    ref: main
    file: 'universal-pipeline.yml'
```
Это тоже рабочий вариант (одна строка руками на новый проект), но раз
цель была именно «применяется само при апдейте/загрузке проекта» —
дальше описан способ без этой ручной строки вообще.

## Автоприменение — без единой ручной строчки в проектах

Механизм — API-поле проекта `ci_config_path` (то же самое, что настройка
«CI/CD configuration file» в Settings → CI/CD → General pipelines):
говорит GitLab, где искать конфиг пайплайна, включая **внешний** файл в
другом проекте (`файл@namespace/project`). Если проставить его на
`universal-pipeline.yml@devops/ci-templates` — GitLab при каждом push
берёт роутер оттуда, без единого файла в самом проекте.

Проставляется двумя частями:

**Новые проекты — автоматически, через n8n**
`config/n8n/workflows/gitlab-auto-ci-router.json` — слушает GitLab
**System Hook** (событие `project_create`, шлётся при создании ЛЮБОГО
нового проекта на всём инстансе) и сразу проставляет `ci_config_path`
через API. Настройка:
1. Импортировать workflow в n8n, активировать, привязать credential
   `GitLab API` (та же, что уже используется в остальных workflow).
2. В коде ноды `Filter Project Create` вписать `SECRET_TOKEN` —
   произвольную строку, которую дальше вписать в сам хук (см. ниже).
3. GitLab: **Admin Area → System Hooks → Add new system hook**:
   - URL: `http://n8n:5678/webhook/gitlab-system-hook` (внутренний
     docker-network адрес, тот же паттерн, что и у остального n8n —
     публично никуда не торчит, GitLab и n8n на одном `devops_edge`);
   - Secret Token: то же значение, что вписали в ноду;
   - Trigger: достаточно "Enable SSL verification" по умолчанию, отдельной
     галочки под `project_create` нет — System Hook шлёт все системные
     события разом, workflow сам фильтрует по `event_name`.
4. Проверка: создать тестовый пустой проект в GitLab → в Settings → CI/CD
   → General pipelines → «CI/CD configuration file» должно само
   появиться `universal-pipeline.yml@devops/ci-templates`.

**Уже существующие проекты — один раз, скриптом**
System Hook ловит только НОВЫЕ проекты. Для того, что уже есть —
`scripts/backfill-ci-router.sh`:
```bash
GITLAB_TOKEN=<personal access token, права api> \
  ./scripts/backfill-ci-router.sh devops/ci-templates universal-pipeline.yml
```
Пройдётся по всем проектам, куда у токена есть доступ, и проставит то
же самое поле. Разовая операция, не нужно перезапускать при каждом
обновлении — дальше все push в эти проекты уже сами используют роутер.

После этих двух шагов — «залил новый проект» и «запушил в существующий»
оба автоматически прогоняют `detect-stack` → нужный официальный шаблон,
без единого действия в самом проекте.

## Текущий набор стеков

| Маркер-файл | Стек | Шаблон GitLab |
|---|---|---|
| `composer.json` | PHP | `PHP.gitlab-ci.yml` |
| `package.json` | Node.js | `Nodejs.gitlab-ci.yml` |
| `requirements.txt` / `pyproject.toml` / `Pipfile` | Python | `Python.gitlab-ci.yml` |
| `AndroidManifest.xml` / `app/build.gradle[.kts]` | Android (Kotlin/Java) | `Android.gitlab-ci.yml` |
| `build.gradle` / `build.gradle.kts` (без Android-маркеров) | Kotlin/JVM (backend) | `Gradle.gitlab-ci.yml` — у GitLab нет отдельного шаблона именно под Kotlin, Kotlin-проекты обычно собираются Gradle |
| ничего не подошло | — | джоба `unknown-stack` падает с понятным сообщением, вместо тихого no-op |

Проверить содержимое любого шаблона перед тем, как полагаться на него:
```bash
curl -sS -H "PRIVATE-TOKEN: <токен>" \
  "https://git.${BASE_DOMAIN}/api/v4/templates/gitlab_ci_ymls/PHP" | jq -r .content
```
(поменять `PHP` на `Nodejs`/`Python`/`Gradle`/`Android`).

Если для PHP `PHP.gitlab-ci.yml` окажется слишком старым/базовым
(там больше про голый `phpunit`) — альтернатива в том же списке
шаблонов: `Composer.gitlab-ci.yml`, ориентирован на `composer install` +
скрипты из `composer.json`. Посмотреть оба и поменять одну строку в
`trigger-php`, если Composer-вариант подойдёт лучше.

## Добавить новый стек

В `config/gitlab-ci/universal-pipeline.yml`:
1. Добавить условие в `detect-stack` (`elif [ -f <маркер> ]; then STACK=<имя>`).
2. Добавить джобу `trigger-<имя>` по образцу существующих — та же
   структура `stage: build`, `needs: ['detect-stack']`, `rules: - if:
   '$STACK == "<имя>"'`, `trigger: include: - template: <ШаблонGitLab>.gitlab-ci.yml`.

Список всех доступных официальных шаблонов — `templates` в этом же
docs-разделе выше (через API), или UI: любой проект → Build → Pipeline
Editor → создать `.gitlab-ci.yml` с нуля → GitLab покажет выпадающий
список с превью.
