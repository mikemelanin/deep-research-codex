---
name: research
description: Run Deep Research Codex when the user asks for web research, a sourced report, or a topic report. Uses the local deep-research-codex checkout through research.sh and saves the final markdown report to Downloads.
---

# Research

Use this skill to run research reports through Deep Research Codex.

## Project Root

Find the project root in this order:

1. `DEEP_RESEARCH_CODEX_HOME` environment variable
2. `/Users/melanin/Vibecoding/projects/deep-research-codex`
3. current workspace if it contains `research.sh`
4. `~/deep-research-codex`

The project root must contain:

- `research.sh`
- `scripts/`
- `gpt-researcher/`
- `.env`

Always run commands from the resolved project root:

```bash
PROJECT_ROOT="${DEEP_RESEARCH_CODEX_HOME:-/Users/melanin/Vibecoding/projects/deep-research-codex}"
if [[ ! -f "$PROJECT_ROOT/research.sh" && -f "$PWD/research.sh" ]]; then
  PROJECT_ROOT="$PWD"
fi
cd "$PROJECT_ROOT"
./research.sh ...
```

Do not run `./research.sh` from the user's current workspace unless that workspace is the resolved project root.

## When to Use

Use this skill when the user asks to:

- research a topic
- collect a web report with sources
- generate a markdown research report
- run deep research

Do not use it for changing GPT Researcher internals or debugging unrelated code.

## Default Workflow

For Codex runs, use the controlled two-step flow:

1. Run prefilter only:

```bash
cd "$PROJECT_ROOT"
./research.sh --prefilter-only "<topic>"
```

2. Read stdout and capture:

- `PREFILTER_ARTIFACT`
- `PREFILTER_BRIEF`
- `PREFILTER_QUERY`

3. Show the brief and query to the user.
4. Ask whether to continue.
5. If the user approves, continue from the saved artifact:

```bash
cd "$PROJECT_ROOT"
./research.sh --from-prefilter "<artifact-path>"
```

Language contract:

- Default final report language is English.
- Do not infer Russian output from the user's message language.
- Add `--ru` to both commands only when the user explicitly asks for Russian output, for example "на русском", "по-русски", or "русский отчет".

## File Input

If the user gives a markdown file, pass it as file input:

```bash
cd "$PROJECT_ROOT"
./research.sh --prefilter-only --file "/absolute/path/to/context.md"
```

Then continue from the produced prefilter artifact.

Markdown files are treated as request input, not as a local knowledge base.

## Direct Commands

Use direct mode only when the user clearly wants one-shot execution:

```bash
cd "$PROJECT_ROOT"
./research.sh "<topic>"
./research.sh --ru "<topic>"
./research.sh --yes "<topic>"
```

## Output

On success, report the final saved markdown path from script output:

- `Saved report: ...`

Default output is English, including when the input request is written in Russian. Russian output is produced only when `--ru` is used.

## Error Mapping

If a run fails, summarize the practical reason:

- missing config: `.env` is absent or incomplete
- search auth: `TAVILY_API_KEY` is missing or invalid
- Bedrock auth: AWS credentials or bearer token failed
- Bedrock region: wrong or missing region
- model access: selected Claude model is not callable
- venv: `.venv` is missing or dependencies are not installed

Never print secrets from `.env`.
