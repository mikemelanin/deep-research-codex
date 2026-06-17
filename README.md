# Local GPT Researcher Runner

This repo is a local wrapper around GPT Researcher.

Project layout:

- `deep-research-codex/` - this repo
- `deep-research-codex/gpt-researcher/` - separate GPT Researcher checkout

## Setup

```bash
git clone https://github.com/mikemelanin/deep-research-codex.git
cd deep-research-codex

# clone GPT Researcher into the expected subfolder
git clone https://github.com/assafelovic/gpt-researcher.git gpt-researcher

cp .env.example .env
# Fill values in .env
```

Important:

- this repo does not include the GPT Researcher source code
- `gpt-researcher/` is intentionally ignored in `.gitignore`
- the runner expects GPT Researcher at `./gpt-researcher`

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

Default behavior:

- runs deep research with the local default profile (`4/2/4`)
- saves the final report in English

Translate the final report to Russian:

```bash
./research.sh --ru "Your topic here"
```

Prepare normalized brief/query only:

```bash
./research.sh --prefilter-only "Your topic here"
```

Continue from saved prefilter artifact:

```bash
./research.sh --from-prefilter "./logs/YYYYMMDD-HHMMSS-prefilter.json"
```

Legacy compatibility flags still work, but are no longer the main path:

```bash
./research.sh --deep "Your topic here"
./research.sh --no-translate "Your topic here"
./research.sh --en "Your topic here"
```

Skip confirmation prompt:

```bash
./research.sh --yes "Your topic here"
```

Run from a markdown note (file is used as query input only):

```bash
./research.sh --file "./context.md"
```

Shortcut: pass `.md` path directly (without `--file`):

```bash
./research.sh "./context.md"
```

How pipeline works now:

- input (`inline text` or `file_as_query`) is treated as raw request
- prefilter LLM rewrites it into `# Research task` markdown + compact web query
- `--prefilter-only` stops after that step and saves a reusable artifact in `logs/`
- `--from-prefilter` resumes from saved normalized query without repeating prefilter
- in interactive terminal runs, script asks to confirm normalized brief/query before paid web research starts
- GPT Researcher always runs with `report_source=web`
- default report type is `deep`
- markdown file is not loaded as local context source for report generation

Output file format:

- final saved report: `~/Downloads/YYYY-MM-DD-topic.md` in English by default
- `--ru` translates the final saved report to Russian
- source English report: `gpt-researcher/outputs/<uuid>.md`

Phase diagnostics in run log:

- `phase_start name=...`
- `phase_done name=... duration_s=... reason=...`

`research.sh` performs preflight checks:

- `.env` exists
- `TAVILY_API_KEY` exists
- Bedrock settings use `bedrock:` models
- AWS creds and region are valid
- Claude model is callable via Bedrock
- only one run can be active at a time; concurrent second start is rejected

## Compare deep profiles

Run the built-in comparison runner on one topic with one shared prefilter artifact:

```bash
./.venv/bin/python scripts/compare_deep_profiles.py "Your topic here"
```

What it does:

- generates one reusable `prefilter.json`
- runs three deep profiles on the same normalized query
- saves per-profile `report/log/telemetry`
- writes `comparison-summary.md` and `comparison-summary.json` under `logs/<timestamp>-deep-compare-.../`
