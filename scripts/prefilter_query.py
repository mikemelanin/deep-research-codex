#!/usr/bin/env python3
import json
import os
import re
import sys
from pathlib import Path

import boto3


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: prefilter_query.py <raw_input_file> <brief_out_file> <query_out_file>", file=sys.stderr)
        return 2

    input_path = Path(sys.argv[1])
    brief_path = Path(sys.argv[2])
    query_path = Path(sys.argv[3])

    region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
    model_id = os.getenv("SMART_LLM", "")
    if model_id.startswith("bedrock:"):
        model_id = model_id.split(":", 1)[1]

    raw = input_path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n").strip()
    if not raw:
        print("Error: empty input for prefilter", file=sys.stderr)
        return 1
    if len(raw) > 45000:
        raw = raw[:45000]

    client = boto3.client("bedrock-runtime", region_name=region)

    brief_prompt = f"""
You are a research prefilter.
Transform raw voice-dump or messy notes into a clean research brief.

Return markdown only, exactly this structure and headings:
# Research task
## Topic
...
## Goal
...
## Context
...
## Key questions
1. ...
2. ...
## Scope
Include: ...
Exclude: ...
## Output format
Practical recommendation + comparison table + risks.

Rules:
- Keep it concise, clear, and actionable.
- Fill missing parts with reasonable assumptions from input.
- Keep product/company names exact.
- Do not add extra sections.

Input:
{raw}
"""

    brief_resp = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": brief_prompt}]}],
        inferenceConfig={"maxTokens": 2200, "temperature": 0},
    )
    print(
        "TELEMETRY_JSON "
        + json.dumps(
            {
                "type": "prefilter_bedrock",
                "model": model_id,
                "usage": brief_resp.get("usage", {}),
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    brief = brief_resp["output"]["message"]["content"][0]["text"].strip()

    if not brief.startswith("# Research task"):
        brief = (
            "# Research task\n"
            "## Topic\n"
            "AI agents and workflow platforms\n"
            "## Goal\n"
            "Build an enterprise-ready comparison and recommendation.\n"
            "## Context\n"
            f"{raw[:1200]}\n"
            "## Key questions\n"
            "1. Which platforms fit enterprise rollouts best?\n"
            "2. What is the fastest low-code prototype path?\n"
            "## Scope\n"
            "Include: architecture, security, guardrails, evals, TCO.\n"
            "Exclude: consumer-only use cases.\n"
            "## Output format\n"
            "Practical recommendation + comparison table + risks.\n"
        )

    query_prompt = f"""
Create one compact English web research query from this brief.

Rules:
- 180 to 360 characters.
- Single paragraph.
- Include topic, target audience/business context, and evidence focus.
- No markdown, no bullets.

Brief:
{brief}
"""

    query_resp = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": query_prompt}]}],
        inferenceConfig={"maxTokens": 260, "temperature": 0},
    )
    print(
        "TELEMETRY_JSON "
        + json.dumps(
            {
                "type": "prefilter_bedrock",
                "model": model_id,
                "usage": query_resp.get("usage", {}),
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    query = query_resp["output"]["message"]["content"][0]["text"].strip()
    query = re.sub(r"\s+", " ", query).strip()

    if len(query) > 360:
        query = query[:360].rstrip()
    if len(query) < 80:
        query = (
            "Compare enterprise AI agent and workflow platforms for B2B deployment, "
            "focusing on architecture, workflow-vs-agent logic, RAG, MCP/tools, guardrails, "
            "evals, audit, security, and low-code prototyping path for solution sales and consulting."
        )

    brief_path.write_text(brief.strip() + "\n", encoding="utf-8")
    query_path.write_text(query + "\n", encoding="utf-8")
    print(query)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
