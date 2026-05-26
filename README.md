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

Explicit web-only mode (same behavior as default for `--file`):

```bash
./research.sh --file "/Users/melanin/Downloads/context.md" --file-mode query
```

Legacy hybrid mode (only when you explicitly need local DOC_PATH context):

```bash
./research.sh --file "/Users/melanin/Downloads/context.md" --file-mode source
```

Optional brief claim verification (adds verification table to report):

```bash
./research.sh --file "/Users/melanin/Downloads/context.md" --verify-brief
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

For `--file`, the script supports two modes:

- default `--file-mode query`:
  - runs `report_source=web`
  - markdown is used only to create a compact web query
  - no `DOC_PATH` local-context loading
- legacy `--file-mode source`:
  - runs `report_source=hybrid`
  - markdown is loaded as local context via `DOC_PATH`
  - on hybrid failure, script auto-falls back to web mode

For `--file --verify-brief`, a post-check section is appended to the report:

- `## Brief Claim Verification`
- table columns: `Claim | Status | Evidence URL | Note`
- statuses: `verified`, `conflicting`, `unverified`
- only external URLs are treated as evidence (brief text itself is not evidence)

Phase diagnostics in run log:

- `phase_start name=...`
- `phase_done name=... duration_s=... reason=...`

`research.sh` performs preflight checks:

- `.env` exists
- `TAVILY_API_KEY` exists
- Bedrock settings use `bedrock:` models
- AWS creds and region are valid
- Claude model is callable via Bedrock
