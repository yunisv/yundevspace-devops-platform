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
3. В любом проекте, где нужно автоопределение стека, `.gitlab-ci.yml`
   становится одной строкой:
   ```yaml
   include:
     - project: 'devops/ci-templates'
       ref: main
       file: 'universal-pipeline.yml'
   ```
   (путь `devops/ci-templates` — поправить на реальный namespace/имя
   проекта, который создали в шаге 1).
4. Push в этот проект → `detect-stack` смотрит на маркер-файлы → триггерит
   child pipeline с нужным официальным шаблоном.

Это не полностью «zero-touch» — одна строка `include:` в каждом проекте
всё равно нужна (в отличие от Auto DevOps по умолчанию для всего
инстанса/группы, который вообще не требует ничего в проекте). Если
нужно совсем без этой строки — можно комбинировать: этот роутер как
основной путь, Auto DevOps как fallback для проектов без своего
`.gitlab-ci.yml` вообще.

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
