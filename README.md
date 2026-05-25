# Local GPT Researcher Runner

Root: `/Users/melanin/Vibecoding/projects/gpt-researcher`

## Setup

```bash
cd /Users/melanin/Vibecoding/projects/gpt-researcher
cp .env.example .env
# Fill values in .env
```

## Required keys and access

- `TAVILY_API_KEY`: create at https://app.tavily.com
- AWS Bedrock access to Claude model in your selected region

You must set in `.env`:

- `RETRIEVER=tavily`
- `FAST_LLM`, `SMART_LLM`, `STRATEGIC_LLM` as `bedrock:<model_id>`
- `EMBEDDING=bedrock:amazon.titan-embed-text-v2:0`
- AWS auth (`AWS_PROFILE` or key pair)
- `AWS_DEFAULT_REGION`

## Run research

```bash
./research.sh "Your topic here"
```

Research from a markdown brief:

```bash
./research.sh --file "/Users/melanin/Downloads/context.md"
```

You can add a specific focus after the file:

```bash
./research.sh --file "/Users/melanin/Downloads/context.md" "focus on competitors and ROI"
```

English-only mode:

```bash
./research.sh --en "Your topic here"
```

Output file format:

- default: `~/Downloads/YYYY-MM-DD-topic.md`
- with `--en`: `~/Downloads/YYYY-MM-DD-topic.md`

For `--file`, the script uses GPT Researcher hybrid mode:

- the markdown file is loaded as local context via `DOC_PATH`
- Bedrock creates a concise research query from the file
- Tavily/web search validates and expands the brief with external sources

`research.sh` performs preflight checks:

- `.env` exists
- `TAVILY_API_KEY` exists
- Bedrock settings use `bedrock:` models
- AWS creds and region are valid
- Claude model is callable via Bedrock
