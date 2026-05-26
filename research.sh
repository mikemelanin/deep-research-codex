#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/gpt-researcher"
REPORTS_DIR="$HOME/Downloads"
ENV_FILE="$ROOT_DIR/.env"
LOGS_DIR="$ROOT_DIR/logs"

if [[ $# -lt 1 ]]; then
  echo "Usage: ./research.sh [--ru|--en] [--file /path/context.md | \"topic\"]"
  exit 1
fi

TRANSLATE_TO_RU=1
FILE_MODE=0
INPUT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ru)
      TRANSLATE_TO_RU=1
      shift
      ;;
    --en)
      TRANSLATE_TO_RU=0
      shift
      ;;
    --file)
      if [[ $# -lt 2 ]]; then
        echo "Error: --file requires a path"
        exit 1
      fi
      FILE_MODE=1
      INPUT_FILE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option '$1'"
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ "$FILE_MODE" -eq 0 && $# -lt 1 ]]; then
  echo "Usage: ./research.sh [--ru|--en] [--file /path/context.md | \"topic\"]"
  exit 1
fi

QUERY="$*"
FILE_TASK="$QUERY"
REPORT_SOURCE="web"
TEMP_DOC_DIR=""

if [[ "$FILE_MODE" -eq 1 ]]; then
  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: input file not found: $INPUT_FILE"
    exit 1
  fi
  INPUT_FILE="$(python3 - "$INPUT_FILE" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve())
PY
)"
  REPORT_SOURCE="hybrid"
fi

if [[ ! -d "$APP_DIR" || ! -f "$APP_DIR/cli.py" ]]; then
  echo "Error: GPT Researcher not found at $APP_DIR"
  exit 1
fi

if [[ ! -f "$ROOT_DIR/.venv/bin/activate" ]]; then
  echo "Error: virtualenv not found. Create it first: python3 -m venv .venv"
  exit 1
fi

source "$ROOT_DIR/.venv/bin/activate"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "Error: .env not found at $ENV_FILE"
  echo "Create it from .env.example"
  exit 1
fi

# Prevent boto3 from using empty profile names from .env placeholders.
if [[ "${AWS_PROFILE:-}" == "" ]]; then
  unset AWS_PROFILE
fi

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "Error: TAVILY_API_KEY is missing in .env"
  exit 1
fi

: "${RETRIEVER:=tavily}"

for var in FAST_LLM SMART_LLM STRATEGIC_LLM; do
  val="${!var:-}"
  if [[ -z "$val" ]]; then
    echo "Error: $var is missing in .env"
    exit 1
  fi
  if [[ "$val" != bedrock:* ]]; then
    echo "Error: $var must start with 'bedrock:'"
    exit 1
  fi
done

if [[ "${FAST_LLM:-}" == bedrock:* || "${SMART_LLM:-}" == bedrock:* || "${STRATEGIC_LLM:-}" == bedrock:* ]]; then
  if [[ -z "${LLM_KWARGS:-}" ]]; then
    # Raise Bedrock client read timeout above SDK default (60s) to reduce long-call failures.
    export LLM_KWARGS='{"timeout":300,"max_retries":8}'
    echo "LLM_KWARGS not set; using default Bedrock client settings: $LLM_KWARGS"
  fi
fi

if [[ -z "${AWS_DEFAULT_REGION:-}" && -z "${AWS_REGION:-}" ]]; then
  echo "Error: set AWS_DEFAULT_REGION (or AWS_REGION) in .env"
  exit 1
fi

HAS_BEARER=0
HAS_AWS_CREDS=0
if [[ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]]; then
  HAS_BEARER=1
fi
if [[ -n "${AWS_PROFILE:-}" ]] || [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  HAS_AWS_CREDS=1
fi
if [[ "$HAS_BEARER" -eq 0 && "$HAS_AWS_CREDS" -eq 0 ]]; then
  echo "Error: provide either AWS_BEARER_TOKEN_BEDROCK or AWS_PROFILE/AWS_ACCESS_KEY_ID+AWS_SECRET_ACCESS_KEY"
  exit 1
fi

BEDROCK_MODEL_ID="${SMART_LLM#bedrock:}"

python - <<'PY'
import os
import sys
import boto3
from botocore.exceptions import BotoCoreError, ClientError

region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
model_id = os.getenv("SMART_LLM", "")
if not model_id.startswith("bedrock:"):
    print("Error: SMART_LLM must start with 'bedrock:'")
    sys.exit(1)
model_id = model_id.split(":", 1)[1]

profile = os.getenv("AWS_PROFILE") or None

try:
    bearer = os.getenv("AWS_BEARER_TOKEN_BEDROCK")
    if bearer:
        # Bedrock API key (bearer token) flow - no STS check required.
        runtime = boto3.client("bedrock-runtime", region_name=region)
    else:
        # Standard AWS credentials flow.
        if profile:
            session = boto3.Session(profile_name=profile, region_name=region)
        else:
            session = boto3.Session(region_name=region)
        sts = session.client("sts", region_name=region)
        sts.get_caller_identity()
        runtime = session.client("bedrock-runtime", region_name=region)

    runtime.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": "ping"}]}],
        inferenceConfig={"maxTokens": 1, "temperature": 0},
    )

except ClientError as e:
    code = e.response.get("Error", {}).get("Code", "Unknown")
    msg = e.response.get("Error", {}).get("Message", str(e))
    print(f"Bedrock check failed: {code} - {msg}")
    print("Verify AWS creds/profile, AWS_DEFAULT_REGION, model access, and IAM permissions (bedrock:InvokeModel).")
    sys.exit(2)
except BotoCoreError as e:
    print(f"Bedrock check failed: {e}")
    print("Verify AWS credentials and region settings.")
    sys.exit(2)
except Exception as e:
    print(f"Bedrock check failed: {e}")
    sys.exit(2)
PY

echo "Bedrock check passed for model: $BEDROCK_MODEL_ID"

mkdir -p "$REPORTS_DIR"
mkdir -p "$LOGS_DIR"

if [[ "$FILE_MODE" -eq 1 ]]; then
  TEMP_DOC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-research-docs.XXXXXX")"
  trap '[[ -n "${TEMP_DOC_DIR:-}" && -d "$TEMP_DOC_DIR" ]] && rm -rf "$TEMP_DOC_DIR"' EXIT
  cp "$INPUT_FILE" "$TEMP_DOC_DIR/"
  export DOC_PATH="$TEMP_DOC_DIR"
  export INPUT_FILE
  export FILE_TASK

  echo "Preparing hybrid research query from: $INPUT_FILE"
  QUERY="$(python - <<'PY'
import os
from pathlib import Path
import boto3

region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
model_id = os.getenv("SMART_LLM", "")
if model_id.startswith("bedrock:"):
    model_id = model_id.split(":", 1)[1]

source = Path(os.environ["INPUT_FILE"])
content = source.read_text(encoding="utf-8", errors="replace")
file_task = os.getenv("FILE_TASK", "").strip()

prompt = f"""
Create a short English web-research task for GPT Researcher based on this markdown brief.

The task will be used as a web-search seed. The full markdown file is already loaded separately as local context via DOC_PATH, so do not restate the brief.

Rules:
- 350 to 650 characters;
- one compact paragraph;
- mention the core topic, target market, and evidence types to find;
- include key terms that should guide search query generation;
- no markdown headings, bullets, lists, or commentary;
- do not include detailed background or long question lists;
- preserve proper nouns and technical terms.

Return only the final web-research task.

Additional user instruction:
{file_task or "Use the markdown brief itself as the research task."}

Markdown brief:
{content}
"""

client = boto3.client("bedrock-runtime", region_name=region)
resp = client.converse(
    modelId=model_id,
    messages=[{"role": "user", "content": [{"text": prompt}]}],
    inferenceConfig={"maxTokens": 350, "temperature": 0},
)
query = resp["output"]["message"]["content"][0]["text"].strip()

if len(query) > 800:
    compress_prompt = (
        "Compress this web-research task to 350-650 characters. "
        "Keep core topic, market, evidence types, and search terms. "
        "Return one compact paragraph only.\n\n"
        + query
    )
    resp = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": compress_prompt}]}],
        inferenceConfig={"maxTokens": 220, "temperature": 0},
    )
    query = resp["output"]["message"]["content"][0]["text"].strip()

if len(query) > 750:
    cut = query[:750]
    last_period = max(cut.rfind("."), cut.rfind(";"))
    query = cut[:last_period + 1] if last_period > 350 else cut.rstrip()

print(query)
PY
)"
  if [[ -z "$QUERY" ]]; then
    echo "Error: generated research query is empty"
    exit 1
  fi
  echo "Generated web research seed:"
  echo "$QUERY"
  echo "Hybrid DOC_PATH: $DOC_PATH"
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOGS_DIR/${RUN_ID}-research.log"
HYBRID_TIMEOUT_SECONDS="${HYBRID_TIMEOUT_SECONDS:-480}"
WEB_TIMEOUT_SECONDS="${WEB_TIMEOUT_SECONDS:-480}"

log_ts() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$RUN_LOG"
}

{
  echo "run_id=$RUN_ID"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "report_source=$REPORT_SOURCE"
  echo "translate_to_ru=$TRANSLATE_TO_RU"
  echo "input_file=${INPUT_FILE:-}"
  echo "doc_path=${DOC_PATH:-}"
  echo "query_chars=${#QUERY}"
  echo "query:"
  echo "$QUERY"
  echo
  echo "--- raw output ---"
} > "$RUN_LOG"
echo "Run log: $RUN_LOG"

RAW_OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-raw.${RUN_ID}.XXXXXX")"
trap '[[ -n "${TEMP_DOC_DIR:-}" && -d "$TEMP_DOC_DIR" ]] && rm -rf "$TEMP_DOC_DIR"; [[ -n "${RAW_OUTPUT_FILE:-}" && -f "$RAW_OUTPUT_FILE" ]] && rm -f "$RAW_OUTPUT_FILE"' EXIT

run_cli_with_timeout() {
  local source="$1"
  local timeout_sec="$2"
  python - "$APP_DIR" "$QUERY" "$source" "$timeout_sec" "$RAW_OUTPUT_FILE" <<'PY'
import subprocess
import sys
from pathlib import Path

app_dir, query, source, timeout_sec, raw_file = sys.argv[1:]
timeout_sec = int(timeout_sec)
cmd = [
    sys.executable, "cli.py", query,
    "--report_type", "research_report",
    "--report_source", source,
    "--no-pdf", "--no-docx",
]
try:
    proc = subprocess.run(
        cmd,
        cwd=app_dir,
        capture_output=True,
        text=True,
        timeout=timeout_sec,
        env={**dict(), **__import__("os").environ, "PYTHONUNBUFFERED": "1"},
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    Path(raw_file).write_text(out, encoding="utf-8")
    print(out, end="")
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired as e:
    def _norm(v):
        if v is None:
            return ""
        if isinstance(v, bytes):
            return v.decode("utf-8", errors="replace")
        return v
    out = _norm(e.stdout) + _norm(e.stderr)
    Path(raw_file).write_text(out, encoding="utf-8")
    if out:
        print(out, end="")
    print(f"\nError: CLI timed out after {timeout_sec}s for report_source={source}")
    sys.exit(124)
PY
}

EXEC_SOURCE="$REPORT_SOURCE"
RUN_EXIT=0

if [[ "$REPORT_SOURCE" == "hybrid" ]]; then
  log_ts "hybrid_start timeout=${HYBRID_TIMEOUT_SECONDS}s"
  if run_cli_with_timeout "hybrid" "$HYBRID_TIMEOUT_SECONDS"; then
    RUN_EXIT=0
    EXEC_SOURCE="hybrid"
    log_ts "hybrid_success"
  else
    RUN_EXIT=$?
    log_ts "hybrid_failed exit_code=$RUN_EXIT fallback=web"
    log_ts "web_fallback_start timeout=${WEB_TIMEOUT_SECONDS}s"
    if run_cli_with_timeout "web" "$WEB_TIMEOUT_SECONDS"; then
      RUN_EXIT=0
      EXEC_SOURCE="web"
      log_ts "web_fallback_success"
    else
      RUN_EXIT=$?
      log_ts "web_fallback_failed exit_code=$RUN_EXIT"
    fi
  fi
else
  log_ts "web_start timeout=${WEB_TIMEOUT_SECONDS}s"
  if run_cli_with_timeout "web" "$WEB_TIMEOUT_SECONDS"; then
    RUN_EXIT=0
    EXEC_SOURCE="web"
    log_ts "web_success"
  else
    RUN_EXIT=$?
    log_ts "web_failed exit_code=$RUN_EXIT"
  fi
fi

RAW_OUTPUT="$(cat "$RAW_OUTPUT_FILE")"
printf '%s\n' "$RAW_OUTPUT" >> "$RUN_LOG"

if [[ "$RUN_EXIT" -ne 0 ]]; then
  echo "Error: GPT Researcher execution failed"
  exit "$RUN_EXIT"
fi
echo "effective_report_source=$EXEC_SOURCE" >> "$RUN_LOG"

REPORT_REL_PATH="$(printf '%s\n' "$RAW_OUTPUT" | sed -n "s/.*Report written to '\(outputs\/[^']*\.md\)'.*/\1/p" | tail -n 1)"

if [[ -z "$REPORT_REL_PATH" ]]; then
  echo "Error: could not parse output markdown path from GPT Researcher logs"
  exit 1
fi

SRC_REPORT="$APP_DIR/$REPORT_REL_PATH"
if [[ ! -f "$SRC_REPORT" ]]; then
  echo "Error: generated report not found at $SRC_REPORT"
  exit 1
fi
echo "source_report=$SRC_REPORT" >> "$RUN_LOG"

SLUG="$(python - "$QUERY" <<'PY'
import re
import sys
q = sys.argv[1].strip().lower()
slug = re.sub(r"[^\w]+", "-", q, flags=re.UNICODE).strip("-_")
print((slug[:80] or "topic"))
PY
)"

DATE_STR="$(date +%F)"
BASE_REPORT_PATH="$REPORTS_DIR/${DATE_STR}-${SLUG}"
if [[ "$FILE_MODE" -eq 1 ]]; then
  FILE_STEM="$(basename "$INPUT_FILE")"
  FILE_STEM="${FILE_STEM%.*}"
  SLUG="$(python - "$FILE_STEM" <<'PY'
import re
import sys
q = sys.argv[1].strip().lower()
slug = re.sub(r"[^\w]+", "-", q, flags=re.UNICODE).strip("-_")
print((slug[:80] or "topic"))
PY
)"
  BASE_REPORT_PATH="$REPORTS_DIR/${DATE_STR}-${SLUG}"
fi

if [[ "$TRANSLATE_TO_RU" -eq 1 ]]; then
  log_ts "translation_start mode=ru"
  DEST_REPORT="${BASE_REPORT_PATH}.md"
  export SRC_REPORT DEST_REPORT
  python - <<'PY'
import os
import re
import time
from pathlib import Path
import boto3
from botocore.exceptions import ClientError, BotoCoreError

region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
model_id = os.getenv("SMART_LLM", "")
if model_id.startswith("bedrock:"):
    model_id = model_id.split(":", 1)[1]

src = Path(os.environ["SRC_REPORT"])
dst = Path(os.environ["DEST_REPORT"])
content = src.read_text(encoding="utf-8")

def split_markdown(text: str, max_chars: int = 6500) -> list[str]:
    sections = re.split(r"(?m)(?=^#{1,3}\s+)", text)
    chunks = []
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

    compact_chunks = []
    for chunk in chunks:
        if len(chunk) <= max_chars:
            compact_chunks.append(chunk)
            continue
        paragraphs = re.split(r"\n\s*\n", chunk)
        current = ""
        for paragraph in paragraphs:
            candidate = f"{current}\n\n{paragraph}" if current else paragraph
            if current and len(candidate) > max_chars:
                compact_chunks.append(current.rstrip())
                current = paragraph
            else:
                current = candidate
        if current.strip():
            compact_chunks.append(current.rstrip())
    return compact_chunks

def translate_chunk(client, chunk: str, index: int, total: int) -> str:
    prompt = (
        "Translate this markdown report section to Russian. "
        "Keep markdown structure, headings, links, citations, tables, and formatting unchanged. "
        "Preserve technical terms, product names, framework names, code identifiers, model names, URLs, and source titles in original form unless natural Russian spelling is standard. "
        "Do not add comments, introductions, or extra sections. "
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
            return resp["output"]["message"]["content"][0]["text"].strip()
        except (ClientError, BotoCoreError, Exception) as e:
            if attempt == 3:
                print(f"Warning: RU translation failed for section {index}/{total}: {e}")
                return chunk
            time.sleep(2 * attempt)

try:
    client = boto3.client("bedrock-runtime", region_name=region)
    chunks = split_markdown(content)
    print(f"Translating report to RU in {len(chunks)} section(s)...")
    translated = []
    for i, chunk in enumerate(chunks, start=1):
        print(f"Translating section {i}/{len(chunks)}...")
        translated.append(translate_chunk(client, chunk, i, len(chunks)))
    ru_text = "\n\n".join(translated).strip() + "\n"
    dst.write_text(ru_text, encoding="utf-8")
    print(f"Saved report: {dst}")
except (ClientError, BotoCoreError, Exception) as e:
    print(f"Warning: RU translation failed: {e}")
    dst.write_text(content, encoding="utf-8")
    print(f"Saved report: {dst}")
PY
  log_ts "translation_done"
else
  log_ts "translation_skip mode=en"
  DEST_REPORT="${BASE_REPORT_PATH}.md"
  cp "$SRC_REPORT" "$DEST_REPORT"
  echo "Saved report: $DEST_REPORT"
fi

{
  echo "saved_report=$DEST_REPORT"
  echo "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$RUN_LOG"
echo "Saved log: $RUN_LOG"
