# Deep Research Codex

Локальный раннер для research-задач поверх GPT Researcher.

Внутри репозитория уже лежит встроенная и модифицированная версия `gpt-researcher`, а сверху добавлен локальный workflow для более управляемого запуска:

- нормализация запроса через prefilter
- подтверждение brief/query перед платным web research
- запуск deep research с локальными настройками
- сохранение итогового markdown-отчета
- опциональный перевод финального отчета на русский

Проект основан на GPT Researcher, но содержит локальные изменения под этот сценарий работы.

## Что лежит в репозитории

- `research.sh` - основной вход для запуска исследования
- `scripts/` - вспомогательные скрипты
- `gpt-researcher/` - встроенный исходный код GPT Researcher
- `.env.example` - пример конфигурации

## Установка

```bash
git clone https://github.com/mikemelanin/deep-research-codex.git
cd deep-research-codex
cp .env.example .env
```

После этого заполни `.env`.

Важно:

- секреты должны лежать только в `.env`
- файл `.env` не должен попадать в git
- встроенный `gpt-researcher` уже включен в этот репозиторий, отдельно скачивать его не нужно

## Что нужно для запуска

- `TAVILY_API_KEY`
- доступ к AWS Bedrock
- модель Claude, доступная через Bedrock в нужном регионе

В `.env` должны быть настроены:

- `RETRIEVER=tavily`
- `FAST_LLM`, `SMART_LLM`, `STRATEGIC_LLM` в формате `bedrock:<model_id>`
- `EMBEDDING=bedrock:amazon.titan-embed-text-v2:0`
- AWS-аутентификация: либо `AWS_PROFILE`, либо пара ключей
- `AWS_DEFAULT_REGION`

## Быстрый запуск

Обычный запуск:

```bash
./research.sh "Тема исследования"
```

По умолчанию раннер:

- запускает deep research
- использует локальный профиль по умолчанию `4/2/4`
- сохраняет итоговый отчет на английском

Сразу получить русский итоговый отчет:

```bash
./research.sh --ru "Тема исследования"
```

## Полезные режимы

Сделать только prefilter и сохранить артефакт:

```bash
./research.sh --prefilter-only "Тема исследования"
```

Продолжить из уже сохраненного prefilter-артефакта:

```bash
./research.sh --from-prefilter "./logs/YYYYMMDD-HHMMSS-prefilter.json"
```

Пропустить подтверждение brief/query:

```bash
./research.sh --yes "Тема исследования"
```

Передать markdown-файл как входной запрос:

```bash
./research.sh --file "./context.md"
```

Короткий вариант без `--file`:

```bash
./research.sh "./context.md"
```

Старые флаги совместимости тоже работают:

```bash
./research.sh --deep "Тема исследования"
./research.sh --no-translate "Тема исследования"
./research.sh --en "Тема исследования"
```

## Как устроен workflow

1. Входной текст или markdown-файл воспринимается как сырой запрос.
2. Prefilter LLM превращает его в нормализованный `Research task` и короткий web query.
3. В интерактивном запуске раннер просит подтвердить результат prefilter перед платным поиском.
4. После подтверждения запускается GPT Researcher с `report_source=web`.
5. Итоговый отчет сохраняется в markdown.
6. Если указан `--ru`, после этого делается перевод финального отчета на русский.

Важно:

- по умолчанию используется тип отчета `deep`
- markdown-файл не подмешивается как локальный knowledge source, а используется как текст запроса

## Куда сохраняются результаты

- итоговый отчет по умолчанию: `~/Downloads/YYYY-MM-DD-topic.md`
- исходный английский отчет GPT Researcher: `gpt-researcher/outputs/<uuid>.md`
- логи и prefilter-артефакты: `./logs/`

## Что проверяет `research.sh` перед запуском

- существует `.env`
- задан `TAVILY_API_KEY`
- Bedrock-модели указаны в формате `bedrock:...`
- AWS-креды и регион валидны
- модель Claude реально вызывается через Bedrock
- одновременно может идти только один запуск

## Сравнение deep-профилей

Можно прогнать встроенное сравнение нескольких deep-профилей на одной теме:

```bash
./.venv/bin/python scripts/compare_deep_profiles.py "Тема исследования"
```

Этот сценарий:

- создает один общий `prefilter.json`
- запускает три deep-профиля на одном и том же нормализованном запросе
- сохраняет отдельные `report/log/telemetry`
- пишет `comparison-summary.md` и `comparison-summary.json` в `logs/<timestamp>-deep-compare-.../`
