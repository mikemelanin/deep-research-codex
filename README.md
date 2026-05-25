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

English-only mode:

```bash
./research.sh --en "Your topic here"
```

Output file format:

- default: `~/Downloads/YYYY-MM-DD-topic-ru.md`
- with `--en`: `~/Downloads/YYYY-MM-DD-topic.md`

`research.sh` performs preflight checks:

- `.env` exists
- `TAVILY_API_KEY` exists
- Bedrock settings use `bedrock:` models
- AWS creds and region are valid
- Claude model is callable via Bedrock
