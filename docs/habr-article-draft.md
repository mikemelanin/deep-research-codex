# Как я собрал локальный Deep Research поверх Codex и GPT Researcher

В ChatGPT и Claude уже есть Deep Research: даешь тему, ждешь, получаешь большой отчет с источниками. Это удобно, пока не упираешься в ограничения интерфейса, лимиты, непрозрачность процесса и невозможность нормально встроить это в свой локальный workflow.

Мне хотелось похожую механику, но более управляемую:

- запускать research из Codex обычной фразой;
- видеть, во что агент превратил мой сырой запрос;
- подтверждать brief и web query до платного поиска;
- хранить результат обычным markdown-файлом;
- управлять шириной, глубиной, лимитами и API-ключами локально.

Так появился [Deep Research Codex](https://github.com/mikemelanin/deep-research-codex) - локальный wrapper поверх [GPT Researcher](https://github.com/assafelovic/gpt-researcher), который запускается из Codex как skill.

## Что получилось

Это не новый research engine с нуля. Внутри лежит модифицированный GPT Researcher, а сверху добавлены:

- `research.sh` как основной runner;
- prefilter-этап, который превращает сырой запрос в аккуратный research brief;
- подтверждение перед запуском web research;
- Codex skill, чтобы запускать все это из агента;
- сохранение результата в markdown;
- настройки deep research: breadth, depth, concurrency, soft limits.

Выглядит workflow так:

**[ВСТАВИТЬ КАРТИНКУ 1: простая workflow-схема]**

Источник схемы: `docs/diagrams/codex-skill-workflow.excalidraw`

Смысл простой:

1. Я пишу в Codex: "Сделай research по теме ...".
2. Codex видит `research` skill.
3. Skill запускает prefilter.
4. Prefilter показывает мне brief и web query.
5. Я подтверждаю.
6. Запускается deep research.
7. Итоговый markdown-отчет падает в `~/Downloads`.

## Зачем нужен prefilter

Обычная проблема research-запросов: человек пишет не идеальный поисковый запрос, а человеческий запрос. Иногда это голосовая каша, заметка из нескольких абзацев, список мыслей или просто "разберись, что происходит".

Если сразу отправить это в web research, можно получить дорогой, но кривой прогон. Поэтому я добавил prefilter.

Prefilter делает две вещи:

- превращает сырой input в `Research task`;
- делает компактный web query, с которым уже можно идти в поиск.

И главное - этот шаг можно посмотреть до запуска основного исследования.

Пример:

```text
Сырой запрос:
Нужно понять, какие AI-агенты сейчас реально применяются в клиентской поддержке,
где там ROI, где маркетинг, какие риски, и что можно показать B2B-клиенту.
```

После prefilter это становится нормальным research brief: тема, цель, контекст, ключевые вопросы, scope и формат результата.

Это маленькая вещь, но она сильно меняет ощущение от workflow: research перестает быть черным ящиком.

## Как работает каскад deep research

Самая важная часть - как GPT Researcher раскладывает задачу.

В моем дефолтном профиле сейчас:

```text
breadth = 4
depth = 2
concurrency = 4
```

Грубо:

- `breadth` - сколько research query создается на уровне;
- `depth` - сколько уровней углубления делать;
- `subqueries` - внутренние поисковые вопросы внутри каждой query;
- `concurrency` - сколько query можно выполнять параллельно.

**[ВСТАВИТЬ КАРТИНКУ 2: каскад breadth/depth/subqueries]**

Источник схемы: `docs/diagrams/deep-research-cascade.excalidraw`

Например, на первом уровне создаются четыре query:

```text
Query 1: экономика поддержки
Query 2: качество ответов
Query 3: интеграции
Query 4: риски
```

Внутри каждой query GPT Researcher делает свои subqueries. Например, внутри "экономики поддержки" могут быть:

```text
Subquery 1: сколько стоит контакт-центр?
Subquery 2: где AI снижает cost per ticket?
Subquery 3: какие есть кейсы ROI?
```

После этого появляются источники, выжимка и follow-up вопросы. Если `depth = 2`, эти follow-up вопросы становятся входом для следующего уровня.

На втором уровне ширина уменьшается:

```text
new_breadth = max(2, old_breadth // 2)
```

То есть при `breadth = 4` следующий уровень будет шириной `2`. Идея такая: сначала широко, потом уже глубже и экономнее.

Важно: `concurrency = 4` не означает "умножить количество запросов на 4". Это только параллельность выполнения.

## Что нужно для запуска

Сейчас wrapper из коробки рассчитан на связку:

- Tavily для web search;
- AWS Bedrock для LLM-вызовов;
- Claude-модель через Bedrock;
- Bedrock embeddings.

Оригинальный GPT Researcher поддерживает много LLM-провайдеров: OpenAI, Anthropic, Azure OpenAI, Google, Groq, Mistral, OpenRouter, Ollama, Bedrock и другие. Но конкретно мой wrapper пока Bedrock-first: prefilter, перевод, preflight и telemetry написаны под Bedrock.

Это важное ограничение текущей версии. Универсальный LLM adapter я хочу вынести отдельным следующим шагом.

## Установка

Клонируем репозиторий:

```bash
git clone https://github.com/mikemelanin/deep-research-codex.git
cd deep-research-codex
```

Создаем окружение и ставим зависимости:

```bash
python3 -m venv .venv
./.venv/bin/pip install -r gpt-researcher/requirements.txt boto3
```

Создаем локальный конфиг:

```bash
cp .env.example .env
```

В `.env` нужно положить свои ключи:

- `TAVILY_API_KEY`;
- Bedrock-настройки для `FAST_LLM`, `SMART_LLM`, `STRATEGIC_LLM`;
- AWS region;
- AWS auth через profile, key pair или bearer token.

Пример лежит в `.env.example`.

## Установка Codex skill

Чтобы запускать это из Codex:

```bash
mkdir -p ~/.codex/skills
cp -R skills/research ~/.codex/skills/research
```

Если проект лежит не в `~/deep-research-codex`, можно указать путь:

```bash
export DEEP_RESEARCH_CODEX_HOME="/path/to/deep-research-codex"
```

После этого в Codex можно писать обычным языком:

```text
Сделай research по теме ...
Собери markdown-отчет с источниками ...
Сделай deep research на русском ...
```

## Запуск без Codex

Можно запускать напрямую:

```bash
./research.sh "Тема исследования"
```

Русский итоговый отчет:

```bash
./research.sh --ru "Тема исследования"
```

Только prefilter, без web research:

```bash
./research.sh --prefilter-only "Тема исследования"
```

Продолжить из сохраненного prefilter artifact:

```bash
./research.sh --from-prefilter "./logs/YYYYMMDD-HHMMSS-prefilter.json"
```

Передать markdown-файл как входной запрос:

```bash
./research.sh --file "./context.md"
```

## Что мне в этом нравится

Главное отличие от "просто запустить research" - появляется управляемость.

Я могу:

- увидеть, как агент понял задачу;
- остановиться до платного web research;
- менять параметры глубины и ширины;
- сохранять промежуточные artifacts;
- получать результат в обычном markdown;
- запускать все это из Codex, а не переключаться между интерфейсами.

Это не заменяет ChatGPT Deep Research или Claude Research как продукт. Это скорее попытка собрать похожий контур у себя локально, чтобы он жил рядом с кодом, скриптами и агентами.

## Ограничения

Текущая версия не универсальная.

Сейчас wrapper заточен под:

- Tavily;
- AWS Bedrock;
- Claude через Bedrock;
- локальную работу из shell/Codex.

Внутри GPT Researcher поддержка провайдеров шире, но мой слой вокруг него пока использует Bedrock напрямую. Это видно в prefilter, translation, preflight и telemetry.

Следующий логичный шаг - вынести LLM-вызовы в универсальный adapter, чтобы можно было выбирать OpenAI, Anthropic, OpenRouter, Ollama или Bedrock одним параметром.

## Репозиторий

Код здесь:

https://github.com/mikemelanin/deep-research-codex

Схемы лежат в:

```text
docs/diagrams/
```

README содержит короткую инструкцию установки и запуска.

## Вместо вывода

Я не пытался сделать "идеальный open-source Deep Research". Скорее собрал рабочий контур под свой способ работы: Codex как управляющий слой, GPT Researcher как research engine, Tavily как web search, Bedrock как LLM backend.

Самая важная идея здесь не в конкретной модели и даже не в конкретном search API. Важнее workflow:

```text
сырой запрос -> prefilter -> подтверждение -> deep research -> markdown report
```

Когда research становится воспроизводимым локальным пайплайном, с ним уже можно работать как с инженерным инструментом, а не как с магической кнопкой в web-интерфейсе.
