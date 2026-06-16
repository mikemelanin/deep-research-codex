#!/usr/bin/env python3
import json
import os
import re
import sys
import time
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError


def split_markdown(text: str, max_chars: int = 6500) -> list[str]:
    sections = re.split(r"(?m)(?=^#{1,3}\s+)", text)
    chunks: list[str] = []
    current = ""
    for section in sections:
        if not section.strip():
            continue
        if current and len(current) + len(section) > max_chars:
            chunks.append(current.rstrip())
            current = section
        else:
            current += section
    if current.strip():
        chunks.append(current.rstrip())
    return chunks


def translate_chunk(client, model_id: str, chunk: str, index: int, total: int) -> str:
    prompt = (
        "Translate this markdown report section to Russian. "
        "Keep markdown structure, links, citations, tables, and formatting unchanged. "
        "Translate the report title, section headings, and all narrative prose to Russian. "
        "Preserve technical terms, product names, framework names, code identifiers, model names, URLs, and cited source titles in original form. "
        "Do not add comments or extra sections. "
        f"This is section {index} of {total}; translate only this section.\n\n"
        + chunk
    )
    for attempt in range(1, 4):
        try:
            resp = client.converse(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": prompt}]}],
                inferenceConfig={"maxTokens": 5000, "temperature": 0},
            )
            print(
                "TELEMETRY_JSON "
                + json.dumps(
                    {
                        "type": "translation_bedrock",
                        "model": model_id,
                        "usage": resp.get("usage", {}),
                        "chunk_index": index,
                        "chunk_total": total,
                    },
                    ensure_ascii=False,
                ),
                flush=True,
            )
            return resp["output"]["message"]["content"][0]["text"].strip()
        except (ClientError, BotoCoreError, Exception):
            if attempt == 3:
                return chunk
            time.sleep(2 * attempt)
    return chunk


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: translate_report_ru.py <src_report> <dest_report>", file=sys.stderr)
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])

    region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
    model_id = os.getenv("SMART_LLM", "")
    if model_id.startswith("bedrock:"):
        model_id = model_id.split(":", 1)[1]

    content = src.read_text(encoding="utf-8")

    try:
        client = boto3.client("bedrock-runtime", region_name=region)
        chunks = split_markdown(content)
        print(f"Translating report to RU in {len(chunks)} section(s)...")
        translated = []
        for i, chunk in enumerate(chunks, start=1):
            print(f"Translating section {i}/{len(chunks)}...")
            translated.append(translate_chunk(client, model_id, chunk, i, len(chunks)))
        dst.write_text("\n\n".join(translated).strip() + "\n", encoding="utf-8")
        print(f"Saved report: {dst}")
        return 0
    except Exception as e:
        print(f"Warning: RU translation failed: {e}")
        dst.write_text(content, encoding="utf-8")
        print(f"Saved report: {dst}")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
