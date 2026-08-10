# SSDLC-пайплайн: 2 репозитория, автозапуск на каждый проект

Секьюрити-пайплайн (secret-scan, SAST несколькими сканерами на язык,
SCA, SBOM, container/IaC-скан, antivirus, импорт в DefectDojo),
собранный по схеме из двух репозиториев:

- **`devops/ssdlc`** — policy-шлюз. Единственный файл — `ssdlc.yml`.
  Ничего не сканирует сам, решает только "когда" (`workflow:rules:` по
  ветке/тегу — три режима, см. ниже) и "с какими параметрами"
  (`PIPELINE_MODE`/`ANTIVIRUS`), подключает `pipeline.yml` из другого
  репозитория через `include: - project:`. Это то, на что указывают
  сами проекты (`ci_config_path`).
- **`devops/pipelines`** — вся реальная работа. `pipeline.yml` —
  оркестратор (стадии + `local:`-инклюды), плюс сами файлы сканеров —
  всё в одном репозитории. Это чисто "библиотека" файлов — GitLab
  никогда не запускает pipeline ЭТОГО проекта напрямую, поэтому
  собственный `ci_config_path`/`.gitlab-ci.yml` там не нужен вообще,
  файлы просто читаются по имени через `include`.

Не путать с [`docs/universal-pipeline.md`](universal-pipeline.md) —
тот билд-роутер по стеку (детект языка → официальный GitLab-шаблон
сборки) сделан раньше и не про безопасность; его файлы остаются в
репозитории, но этот SSDLC-пайплайн с ним не связан и его не
переиспользует.

## Почему именно так (баги в исходном черновике)

Пользователь прислал черновик (`ssdlc.yml`/`pipeline.yml`/
`secretscan.yml`) с несколькими проблемами, поправленными при
реализации:

- Три джобы с одним именем `trufflehog` в одном YAML — невалидно, в
  YAML-мапе выживает только последняя. Сделано одной джобой.
- `exsist:` → правильный ключ `exists:`.
- Черновик пытался передавать параметр через
  `inputs: antivitus: [["inputs.ativirus"]]` и `include: - local:
  pipeline.yml` — синтаксис `$[[ inputs.x ]]`/`inputs:` был правильным
  инстинктом, но написан с ошибками (двойные скобки массива, `local:`
  вместо кросс-репо). Изначально (первая версия этого пайплайна)
  сознательно отказались от `spec:/inputs:` вообще, посчитав, что это
  требует формального versioned CI/CD Components каталога — **это
  оказалось неверно**: сравнение с реальным production SSDLC другой
  команды показало, что `spec: inputs:` + `$[[ inputs.x ]]` прекрасно
  работает через обычный `include: - project: file: inputs: {...}`,
  без каталога и тегов вообще — единственное требование, чтобы у
  целевого файла был свой `spec:` блок. Поэтому позже перевели
  `ssdlc.yml`/`pipeline.yml` на нормальные типизированные `inputs`
  (см. `pipeline.yml` — `spec: inputs: pipeline_mode/antivirus`)
  вместо голых CI/CD-переменных.
- `trufflesecurity -o truflehog.json` — не настоящая CLI-команда,
  заменено на `trufflehog filesystem . --json > trufflehog-report.json`.
- **Более серьёзная архитектурная ошибка, найденная уже на живом
  тестировании** (не из черновика — моя собственная): первая версия
  `ssdlc.yml` подключала `devops/pipelines` через `trigger: project:
  devops/pipelines` (multi-project pipeline). Это запускает ОТДЕЛЬНЫЙ
  пайплайн в контексте `devops/pipelines`, со своим собственным git
  checkout — сканеры реально проверяли репозиторий `devops/pipelines`
  (просто набор YAML-файлов), а не код проекта, который пушили.
  Подтвердилось логом: `Checking out ... in
  /builds/devops/pipelines/.git/` вместо ожидаемого пути исходного
  проекта. Из-за этого все находки были пустыми ("no package sources
  found" и т.п.) — сканировался не тот репозиторий.
  Исправлено на `include: - project: 'devops/pipelines' file:
  'pipeline.yml'` — кросс-репозиторный include мёржит джобы из
  внешнего файла В ТЕКУЩИЙ пайплайн, git checkout остаётся тем, что
  реально запушили. Заодно избавились от костыля `SOURCE_PROJECT_PATH`
  (был нужен только чтобы прокинуть путь через `trigger: variables:` —
  с `include:` `$CI_PROJECT_PATH` и так корректен напрямую).

## Автоприменение — нативная настройка GitLab, без n8n

**Admin Area → Settings → CI/CD → Continuous Integration and
Deployment → "Default CI/CD configuration file"** — доступно в Free
self-managed (не Premium/Ultimate). Вписать туда:
```
ssdlc.yml@devops/ssdlc
```
Все проекты, созданные ПОСЛЕ этого — автоматически получают
`ci_config_path`, указывающий на `ssdlc.yml`, без единого действия в
самом проекте. Работает без n8n и без System Hook — то, что
предлагалось раньше для билд-роутера (`gitlab-auto-ci-router.json`),
для этой задачи не нужно вообще: у GitLab уже есть для этого нативная
настройка.

Существующие проекты (созданные до того, как настройку вписали) — не
подхватывают её задним числом, для них разовый скрипт:
```bash
GITLAB_TOKEN=<personal access token, права api> \
  ./scripts/backfill-ci-router.sh devops/ssdlc ssdlc.yml
```
(тот же `scripts/backfill-ci-router.sh`, что уже был — обновлён по
умолчанию на `devops/ssdlc`/`ssdlc.yml`).

## Настройка (один раз)

1. Создать проект `devops/ssdlc`, запушить туда
   `config/gitlab-ci/ssdlc/ssdlc.yml`.
2. Создать проект `devops/pipelines`, запушить туда содержимое
   `config/gitlab-ci/pipelines/` под теми же именами файлов — этот
   проект НЕ запускает свой собственный пайплайн, файлы читаются по
   имени через `include:` из `ssdlc.yml`, так что переименовывать
   `pipeline.yml` в `.gitlab-ci.yml` или трогать `ci_config_path` этого
   проекта не нужно.
3. На проекте `devops/pipelines` — CI/CD-переменная (Settings → CI/CD
   → Variables, замаскировать): `DEFECTDOJO_TOKEN`. Отдельный
   `DEFECTDOJO_ENGAGEMENT_ID` не нужен — см. ниже, почему.
4. Вписать `ssdlc.yml@devops/ssdlc` в инстанс-настройку (см. выше) —
   для новых проектов, и/или прогнать `backfill-ci-router.sh` — для
   существующих.
5. Тестовый push в любой проект (ветка `main`) → пайплайн ЭТОГО же
   проекта (не отдельный child pipeline) должен пройти по всем стадиям
   из `pipeline.yml` → находки появятся в DefectDojo. Проверить в логе
   любой джобы (`Getting source from Git repository`), что checkout —
   путь реального проекта, не `/builds/devops/pipelines/.git/`.

## Ветковые режимы (fast / full / release)

Два независимых механизма в `ssdlc.yml`, оба на одних и тех же трёх
условиях (тег / `main` / `dev`+`feature/*`):
- `workflow:rules:` — решает, создаётся ли пайплан вообще (просто
  `if:` без `variables:`, последний пункт `when: never` — для любой
  другой ветки пайплайн не создастся).
- `include:` — **три отдельные записи** на тот же `pipeline.yml`,
  каждая со своим `rules:` (та же логика, что и в `workflow:`) и
  своими `inputs: {pipeline_mode, antivirus}` — реально сработает
  только одна из трёх. Значения передаются типизированными `inputs`
  (см. `pipeline.yml`, `spec: inputs:`), которые тот сразу мапит в
  переменные `$PIPELINE_MODE`/`$ANTIVIRUS` — все файлы сканеров
  (`secret-scan.yml`, `sast.yml` и т.д.) продолжают читать их как
  обычные CI/CD-переменные, ничего в них менять не пришлось.

Джобы в `devops/pipelines`, которые не должны бежать на каждый push
при обычной разработке, гейтятся первым пунктом в своих `rules:` на
`PIPELINE_MODE == "fast"` → `when: never`.

| Триггер | `PIPELINE_MODE` | `ANTIVIRUS` | Что бежит |
|---|---|---|---|
| тег | `release` | `true` | всё, включая antivirus |
| `main` | `full` | `false` | всё, кроме antivirus |
| `dev`, `feature/*` | `fast` | `false` | только `secret` + `sast` |

**Не проверено живым тестом на момент написания** (честно предупреждаю
— как и с образами в `docs/scanner-images.md`): дублирование условия
между `workflow:rules:` и `include:rules:` в одном файле — рабочий
паттерн в теории, но если на практике GitLab не даст ожидаемый
`PIPELINE_MODE`/`ANTIVIRUS` долетать до джоб (например из-за порядка
вычисления `include:` относительно `workflow:`) — проверить по логу
любой джобы (`echo $PIPELINE_MODE` быстро добавить в `script:` любой
джобы для диагностики, как раньше делали для `SOURCE_PROJECT_PATH`).

`secret-scan-*` и `sast-*` джобы не гейтятся по `PIPELINE_MODE` —
бегут в любом режиме, это самые быстрые и самые критичные проверки.
Остальные стадии (`sbom`/`sca`/`container`/`iac`) — пропускаются
целиком в fast-режиме.

## Этапы пайплайна

| Стадия | Джобы | Условие запуска | Инструмент |
|---|---|---|---|
| `secret` | `secret-scan-gitleaks` | всегда | gitleaks (быстрый regex, высокий recall) |
| | `secret-scan-trufflehog` | всегда | trufflehog (верификация "секрет живой", меньше false positive) |
| `sast` | `sast-bandit` | есть `*.py` | bandit |
| | `sast-semgrep` | есть `*.py`/`*.js`/`*.ts`/`*.php`/`*.go` | semgrep (`--config auto`) |
| | `sast-gosec` | есть `*.go` | gosec |
| | `sast-eslint-security` | есть `*.js`/`*.ts` | ESLint + eslint-plugin-security |
| | `sast-njsscan` | есть `*.js`/`*.ts` | njsscan |
| `sbom` | `sbom` | не fast | Syft → CycloneDX JSON (вход для `sca-grype` ниже) |
| `sca` | `sca-grype` | не fast (`needs: sbom`) | Grype — сканирует готовый `sbom.json`, второе мнение по CVE-матчингу |
| | `sca-osv-scanner` | не fast | OSV-Scanner — низкий false-positive rate, широкое покрытие экосистем |
| | `sca-pip-audit` | не fast, есть `*.py` | pip-audit |
| | `sca-npm-audit` | не fast, есть `package.json` | `npm audit` |
| | `sca-retirejs` | не fast, есть `package.json` | retire.js |
| | `sca-govulncheck` | не fast, есть `*.go` | govulncheck |
| `container` | `container-scan-trivy` | не fast, есть `Dockerfile` | Trivy (filesystem scan) |
| | `container-scan-trivy-license` | не fast | Trivy (`--scanners license`) — license compliance, отдельно от vuln-отчёта |
| | `container-scan-grype` | не fast, есть `Dockerfile` | Grype — второе мнение |
| | `container-scan-hadolint` | не fast, есть `Dockerfile` | hadolint — линтер Dockerfile (best practices, не уязвимости) |
| `iac` | `iac-scan-checkov` | не fast, есть `*.tf`/`k8s/`/`kubernetes/`/`helm/` | Checkov |
| | `iac-scan-trivy` | не fast, тот же exists | `trivy config` |
| `antivirus` | `antivirus` | `$ANTIVIRUS == "true"` (только на тегах) | ClamAV |
| `dd-import` | `defectdojo-import` | `$SEC_ENABLE != "false"` | curl-импорт всех найденных отчётов в DefectDojo |

Для Python получается 3 сканера (bandit + semgrep + pip-audit) плюс
универсальные grype/osv-scanner, для JS/TS — 5 языко-специфичных
(semgrep + eslint-security + njsscan + npm-audit + retire.js) плюс те
же универсальные — то есть даже больше, чем "для .py 3-4 сканера, для
.js 5 сканеров" из исходного запроса, при полном (не fast) режиме.

**Почему добавлены вторые инструменты там, где раньше был один** (см.
план сессии для источников): gitleaks+trufflehog — разные сильные
стороны (скорость/recall vs верификация); grype — сканирует уже
готовый SBOM, не гоняет инвентарь заново, более строгий CVE-матчинг;
osv-scanner — низкий false positive; `trivy config` рядом с Checkov —
tfsec (была бы третьей опцией) официально deprecated в 2026, все его
чеки перенесены в сам Trivy.

DAST (динамическое сканирование запущенного приложения) сознательно не
включён — требует реального URL задеплоенного окружения, не
универсализируется так же просто; можно добавить отдельным
опциональным этапом позже.

## Переменные-тумблеры (SEC_ENABLE и т.д.)

По образцу реального enterprise-пайплайна коллеги (там джоба
`Devsecops:` принимает набор CI/CD-переменных для точечного
включения/выключения категорий сканов) — добавлен такой же гейтинг
через обычные CI/CD-переменные проекта (Settings -> CI/CD ->
Variables), НЕЗАВИСИМО от `pipeline_mode`/`$[[ inputs.x ]]` (см. ниже,
почему это два разных механизма).

| Переменная | Что гейтит | По умолчанию |
|---|---|---|
| `SEC_ENABLE` | весь SSDLC-пайплайн целиком (все стадии кроме отключаемых по отдельности) | не задана = включено |
| `SECRETS_SCAN_ENABLE` | `secret-scan.yml` (gitleaks, trufflehog) | не задана = включено |
| `CODE_SCAN_ENABLE` | `sast.yml` (все 5 джоб) | не задана = включено |
| `SCA_ENABLE` | `sca.yml` (все 6 джоб) и `sbom.yml` (sbom фидит только sca-grype) | не задана = включено |
| `DEFECTDOJO_URL` | `defectdojo-import.yml` — куда импортировать | не задана = `https://dojo.devops.2be.az` |
| `DOJO_PROJECT_NAME` | `defectdojo-import.yml` — имя Product в DefectDojo | не задана = `$CI_PROJECT_PATH` |

Переменная не задана на проекте — поведение как раньше (всё включено,
дефолтный DefectDojo). Чтобы выключить, например, SCA на конкретном
проекте: выставить `SCA_ENABLE=false` в Settings -> CI/CD -> Variables
этого проекта — джобы `sca-*`/`sbom` пропустятся с `when: never`, в
логе пайплайна будут видны как skipped.

**Это не замена `pipeline_mode`, а дополнение** — два независимых
способа гейтить джобы:
- `pipeline_mode` (`fast`/`full`/`release`, через `spec:inputs:` в
  `pipeline.yml`) — решает АВТОМАТИЧЕСКИ, по ветке/тегу, что должно
  бежать в принципе (fast на dev/feature, full на main, release на
  тегах).
- `SEC_ENABLE`/`SECRETS_SCAN_ENABLE`/`CODE_SCAN_ENABLE`/`SCA_ENABLE` —
  РУЧНОЙ override поверх этого на конкретном проекте (например, у
  легаси-репозитория временно отключить шумный SCA, не трогая общую
  политику веток).

**Что НЕ перенесено из скриншота коллеги и почему**: `SEC_PTAI`,
`SEC_CODEQL` — отдельные сканеры (PT AI, CodeQL), которых в нашем
наборе инструментов нет; `SEC_DUP_FP` — дедупликация false-positive
внутри DefectDojo, требует отдельной логики на стороне DefectDojo,
которую мы не настраивали; `SEC_TASK_CREATOR` — автосоздание тасков
(видимо в Jira/трекере коллеги), у нас нет такой интеграции;
`SEC_GITLAB_EXPORT` — экспорт в нативный GitLab Security Dashboard
формат (`gl-sast-report.json` и т.п.), у нас отчёты идут только в
DefectDojo; `SEC_CLEANUP_ENABLE` — не ясно из скриншота, что именно
чистит (вероятно временные артефакты/старые сканы), нет эквивалентной
логики. Добавлять переменные без реальной функциональности за ними —
создавать иллюзию несуществующей возможности, поэтому осознанно
пропущены; если понадобится что-то из этого — реализовывать как
отдельную задачу.

## Product/Engagement в DefectDojo — авто, без ручного ID

Изначально был один статичный `DEFECTDOJO_ENGAGEMENT_ID` на всех — но
проектов может быть много, и тогда находки ВСЕХ проектов сыпались бы в
один Engagement, перемешиваясь. Вместо этого — DefectDojo умеет сам
заводить Product/Engagement по имени
(`auto_create_context=True` + `product_type_name`/`product_name`/
`engagement_name` в теле запроса `import-scan`, см.
`docs.defectdojo.com/import_data/import_scan_files/api_pipeline_modelling`):
если Product с таким именем ещё нет — создаётся, если есть — импорт
идёт туда же. `product_name` = `$CI_PROJECT_PATH` (предопределённая
переменная GitLab — корректна напрямую, без проброса, раз джобы
подключены через `include:`, а не через `trigger:` на другой проект).
Все находки
у одного проекта — под общим `product_type_name=SSDLC`,
`engagement_name=CI/CD` (постоянный, не разовый Engagement — типичный
паттерн для автоматизированных CI/CD-сканов, находки копятся туда со
временем, не как time-boxed pentest-engagement).

Практический эффект: ничего не нужно заранее заводить в DefectDojo
руками под новый проект — первый же прогон пайплайна сам создаст для
него Product+Engagement с понятным именем.

## DefectDojo scan_type

Подтверждены по `docs.defectdojo.com/supported_tools`: `Bandit Scan`,
`Semgrep JSON Report`, `Gosec Scanner`, `Trufflehog Scan`, `Gitleaks
Scan`, `CycloneDX Scan`, `Trivy Scan` (уже используется в проекте),
`Checkov Scan`. Для остального (pip-audit, npm audit, retire.js,
govulncheck, ESLint, njsscan, Grype ×2, OSV-Scanner, `trivy config`,
ClamAV) — не найден подтверждённый нативный парсер на момент
написания, используется `Generic Findings Import` как fallback —
свериться с `docs.defectdojo.com/supported_tools/parsers/` при
реализации, вдруг появился нативный парсер, тогда поменять
`import_report` вызов в `defectdojo-import.yml` на нужный `scan_type`.

## Добавить новый сканер/язык

В `config/gitlab-ci/pipelines/`:
1. Добавить джобу в соответствующий `*.yml` (`sast.yml`/`sca.yml`/...)
   с `rules: exists:` под нужный маркер-файл. Если джоба "тяжёлая" (не
   должна бежать в fast-режиме) — первым пунктом `rules:` добавить
   `- if: '$PIPELINE_MODE == "fast"' \n  when: never` (см. `sca.yml`
   как образец), если "быстрая" (как secret-scan/SAST) — без этого
   гейта.
2. Добавить `artifacts:` с именем отчёта.
3. Добавить `import_report <файл> "<scan_type>"` в
   `defectdojo-import.yml`.

Добавить новый переключаемый параметр (как `ANTIVIRUS`):
1. `ssdlc.yml` — новая строка в `variables:` нужного `rules:`-пункта.
2. Соответствующая джоба в `devops/pipelines` — `rules: - if:
   '$ИМЯ == "true"'`.

Добавить новый ветковый режим или поменять правила существующих —
только в `ssdlc.yml`, `devops/pipelines` ничего не знает про ветки
напрямую, реагирует только на `PIPELINE_MODE`/`ANTIVIRUS`.

## Git submodules — автоматически для всех проектов

Если у проекта есть submodules (например, отдельный репозиторий
фронтенда, подключённый как submodule) — GitLab по умолчанию их НЕ
чекаутит (`Skipping Git submodules setup` в логе), сканеры видят
пустую директорию-заглушку вместо реального кода. Не нужно проставлять
`GIT_SUBMODULE_STRATEGY` вручную на каждый проект (ни как CI/CD
Variable в UI, ни тем более на группу) — это уже стоит в `ssdlc.yml`
как глобальная `variables: GIT_SUBMODULE_STRATEGY: recursive`,
подхватывается автоматически везде, где используется `ssdlc.yml`.

### Сабмодуль на внешнем хосте (не self-hosted GitLab) — приватный GitHub и т.п.

`CI_JOB_TOKEN`, которым GitLab сам аутентифицирует себя для сабмодулей
на ТОМ ЖЕ инстансе, не работает для внешних хостов (GitHub, GitLab.com
и т.д.) — если такой сабмодуль приватный, клонирование падает:
`fatal: could not read Username for 'https://github.com'`.

`ssdlc.yml` содержит `default: hooks: pre_get_sources_script:` —
выполняется ДО git clone/submodule init (раньше любого
`before_script`, который тут не успел бы), два независимых варианта
подмены URL, каждый — no-op, пока соответствующие переменные не заданы
на проекте:

**Вариант 1 (предпочтительнее, если зеркало есть) — `SUBMODULE_MIRROR_FROM`/`SUBMODULE_MIRROR_TO`.**
Если приватный сабмодуль (например, с GitHub) зазеркалирован в проект
на ЭТОМ ЖЕ self-hosted GitLab — `.gitmodules` остаётся указывать на
исходный внешний хост как есть (обычная разработка не трогается,
пуши продолжают идти на GitHub), а CI подменяет URL на зеркало через
`git config --global url."...".insteadOf` — авторизация через
`CI_JOB_TOKEN` автоматически, никаких секретов заводить не надо.
На проекте (Settings → CI/CD → Variables, обычная переменная, не
Masked — это просто URL, не секрет):
- `SUBMODULE_MIRROR_FROM` = `https://github.com/<org>/<repo>.git`
  (URL, который реально прописан в `.gitmodules`)
- `SUBMODULE_MIRROR_TO` = `git.devops.2be.az/<namespace>/<repo>.git`
  (без схемы `https://` — она подставляется в шаблоне вместе с токеном)

Минус: зеркало не обновляется само при новых коммитах в оригинале —
если разработка продолжается только на исходном хосте, зеркало со
временем "протухнет", CI будет видеть устаревшую версию. Нужен либо
периодический ре-mirror вручную/по расписанию, либо смириться с
задержкой.

**Вариант 2 — `GITHUB_TOKEN`, если зеркала нет и нужен реальный доступ к самому GitHub:**
1. GitHub → Settings → Developer settings → **Fine-grained personal
   access tokens** → создать, scope — только нужный репозиторий,
   права `Contents: Read-only`. Не требует прав администратора над
   самим репозиторием — только собственный read-доступ у того, кто
   создаёт токен.
2. На проекте в GitLab → Settings → CI/CD → Variables → добавить
   `GITHUB_TOKEN` (Masked), значение — токен.

Оба варианта можно использовать одновременно (для разных сабмодулей
одного проекта). Для внешнего хоста, отличного от github.com — вариант
1 сработает для любого хоста (сам URL параметризован), вариант 2
жёстко привязан к `github.com` в шаблоне — при необходимости добавить
ещё один `git config --global url... insteadOf` под нужный хост и
свою переменную.
