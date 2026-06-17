---
name: research
description: Run Deep Research Codex when the user asks for web research, a sourced report, or a topic report. Uses the local deep-research-codex checkout through research.sh and saves the final markdown report to Downloads.
---

# Research

Use this skill to run research reports through Deep Research Codex.

## Project Root

Find the project root in this order:

1. `DEEP_RESEARCH_CODEX_HOME` environment variable
2. current workspace if it contains `research.sh`
3. `~/deep-research-codex`

The project root must contain:

- `research.sh`
- `scripts/`
- `gpt-researcher/`
- `.env`

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
./research.sh --from-prefilter "<artifact-path>"
```

If the user asks for Russian output, add `--ru` to both commands.

## File Input

If the user gives a markdown file, pass it as file input:

```bash
./research.sh --prefilter-only --file "/absolute/path/to/context.md"
```

Then continue from the produced prefilter artifact.

Markdown files are treated as request input, not as a local knowledge base.

## Direct Commands

Use direct mode only when the user clearly wants one-shot execution:

```bash
./research.sh "<topic>"
./research.sh --ru "<topic>"
./research.sh --yes "<topic>"
```

## Output

On success, report the final saved markdown path from script output:

- `Saved report: ...`

Default output is English. Russian output is produced only when `--ru` is used.

## Error Mapping

If a run fails, summarize the practical reason:

- missing config: `.env` is absent or incomplete
- search auth: `TAVILY_API_KEY` is missing or invalid
- Bedrock auth: AWS credentials or bearer token failed
- Bedrock region: wrong or missing region
- model access: selected Claude model is not callable
- venv: `.venv` is missing or dependencies are not installed

Never print secrets from `.env`.
