# SSDLC-пайплайн: 2 репозитория, автозапуск на каждый проект

Секьюрити-пайплайн (secret-scan, SAST несколькими сканерами на язык,
SCA, SBOM, container/IaC-скан, antivirus, импорт в DefectDojo),
собранный по схеме из двух репозиториев:

- **`devops/ssdlc`** — policy-шлюз. Единственный файл — `ssdlc.yml`.
  Ничего не сканирует сам, решает только "когда" (`rules:` — только
  ветка `main`) и "с какими параметрами" (переменные, например
  `ANTIVIRUS: "true"`), передаёт их дальше межпроектным `trigger:`.
  Это то, на что указывают сами проекты (`ci_config_path`).
- **`devops/pipelines`** — вся реальная работа. `pipeline.yml` —
  оркестратор (стадии + `local:`-инклюды), плюс сами файлы сканеров —
  всё в одном репозитории.

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
  pipeline.yml` — это синтаксис GitLab **CI/CD Components**
  (`spec:`/`inputs:`/`$[[ inputs.x ]]`), который требует отдельной
  версионируемой структуры репозитория (`templates/`, git-теги) и
  работает только при подключении через `include: - component: ...`.
  Сознательно не стали делать настоящий Component — сложнее, чем
  нужно для этой задачи. Вместо этого — обычные CI/CD-переменные,
  переданные через `trigger: variables:` (тот же уровень простоты, что
  уже проверен на `universal-pipeline.yml`), и межпроектный
  `trigger: project:` вместо `include: local:` (`local:` работает
  только внутри одного репозитория, а `ssdlc.yml` и `pipeline.yml` —
  в разных).
- `trufflesecurity -o truflehog.json` — не настоящая CLI-команда,
  заменено на `trufflehog filesystem . --json > trufflehog-report.json`.

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
   `config/gitlab-ci/pipelines/` — `pipeline.yml` должен лежать как
   корневой `.gitlab-ci.yml` этого проекта (или явно выставить
   `ci_config_path` = `pipeline.yml` в его настройках) — именно его
   выполняет GitLab, когда `ssdlc.yml` триггерит
   `trigger: project: devops/pipelines`.
3. На проекте `devops/pipelines` — CI/CD-переменные (Settings → CI/CD
   → Variables, замаскировать): `DEFECTDOJO_TOKEN`,
   `DEFECTDOJO_ENGAGEMENT_ID`.
4. Вписать `ssdlc.yml@devops/ssdlc` в инстанс-настройку (см. выше) —
   для новых проектов, и/или прогнать `backfill-ci-router.sh` — для
   существующих.
5. Тестовый push в любой проект (ветка `main`) → должен запуститься
   `devsecops` job в самом проекте → триггернуть child-project pipeline
   в `devops/pipelines` → пройти по стадиям → находки появиться в
   DefectDojo.

## Этапы пайплайна

| Стадия | Джобы | Условие запуска | Инструмент |
|---|---|---|---|
| `secret` | `secret-scan` | всегда | trufflehog |
| `sast` | `sast-bandit` | есть `*.py` | bandit |
| | `sast-semgrep` | есть `*.py`/`*.js`/`*.ts`/`*.php`/`*.go` | semgrep (`--config auto`) |
| | `sast-gosec` | есть `*.go` | gosec |
| | `sast-eslint-security` | есть `*.js`/`*.ts` | ESLint + eslint-plugin-security |
| | `sast-njsscan` | есть `*.js`/`*.ts` | njsscan |
| `sca` | `sca-pip-audit` | есть `*.py` | pip-audit |
| | `sca-npm-audit` | есть `package.json` | `npm audit` |
| | `sca-retirejs` | есть `package.json` | retire.js |
| | `sca-govulncheck` | есть `*.go` | govulncheck |
| `sbom` | `sbom` | всегда | Syft → CycloneDX JSON |
| `container` | `container-scan` | есть `Dockerfile` | Trivy (filesystem scan) |
| `iac` | `iac-scan` | есть `*.tf`/`k8s/`/`kubernetes/`/`helm/` | Checkov |
| `antivirus` | `antivirus` | `$ANTIVIRUS == "true"` (единственный опциональный через переменную) | ClamAV |
| `dd-import` | `defectdojo-import` | всегда | curl-импорт всех найденных отчётов в DefectDojo |

Для Python получается 3 сканера (bandit + semgrep + pip-audit), для
JS/TS — 5 (semgrep + eslint-security + njsscan + npm-audit +
retire.js) — то есть ровно то, что описывал пользователь ("для .py 3-4
сканера, для .js 5 сканеров").

DAST (динамическое сканирование запущенного приложения) сознательно не
включён — требует реального URL задеплоенного окружения, не
универсализируется так же просто; можно добавить отдельным
опциональным этапом позже.

## DefectDojo scan_type

Подтверждены по `docs.defectdojo.com/supported_tools`: `Bandit Scan`,
`Semgrep JSON Report`, `Gosec Scanner`, `Trufflehog Scan`, `CycloneDX
Scan`, `Trivy Scan` (уже используется в проекте), `Checkov Scan`. Для
остального (pip-audit, npm audit, retire.js, govulncheck, ESLint,
njsscan, ClamAV) — не найден подтверждённый нативный парсер на момент
написания, используется `Generic Findings Import` как fallback —
свериться с `docs.defectdojo.com/supported_tools/parsers/` при
реализации, вдруг появился нативный парсер, тогда поменять
`import_report` вызов в `defectdojo-import.yml` на нужный `scan_type`.

## Добавить новый сканер/язык

В `config/gitlab-ci/pipelines/`:
1. Добавить джобу в соответствующий `*.yml` (`sast.yml`/`sca.yml`/...)
   с `rules: exists:` под нужный маркер-файл.
2. Добавить `artifacts:` с именем отчёта.
3. Добавить `import_report <файл> "<scan_type>"` в
   `defectdojo-import.yml`.

Добавить новый переключаемый параметр (как `ANTIVIRUS`):
1. `ssdlc.yml` — новая строка в `trigger: variables:`.
2. Соответствующая джоба в `devops/pipelines` — `rules: - if:
   '$ИМЯ == "true"'`.
