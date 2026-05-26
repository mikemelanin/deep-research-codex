#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/gpt-researcher"
REPORTS_DIR="$HOME/Downloads"
ENV_FILE="$ROOT_DIR/.env"
LOGS_DIR="$ROOT_DIR/logs"

print_usage() {
  echo "Usage: ./research.sh [--ru|--en] [--file /path/context.md [--file-mode source|query] [--verify-brief] [\"extra focus\"] | \"topic\"]"
}

if [[ $# -lt 1 ]]; then
  print_usage
  exit 1
fi

TRANSLATE_TO_RU=1
FILE_MODE=0
INPUT_FILE=""
FILE_MODE_KIND="query"
FILE_MODE_KIND_EXPLICIT=0
VERIFY_BRIEF=0
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
    --file-mode)
      if [[ $# -lt 2 ]]; then
        echo "Error: --file-mode requires 'source' or 'query'"
        exit 1
      fi
      case "$2" in
        source|query)
          FILE_MODE_KIND="$2"
          FILE_MODE_KIND_EXPLICIT=1
          shift 2
          ;;
        *)
          echo "Error: --file-mode must be 'source' or 'query'"
          exit 1
          ;;
      esac
      ;;
    --verify-brief)
      VERIFY_BRIEF=1
      shift
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
  print_usage
  exit 1
fi

if [[ "$FILE_MODE" -eq 0 && "$FILE_MODE_KIND_EXPLICIT" -eq 1 ]]; then
  echo "Error: --file-mode can only be used together with --file"
  exit 1
fi

if [[ "$FILE_MODE" -eq 0 && "$VERIFY_BRIEF" -eq 1 ]]; then
  echo "Error: --verify-brief can only be used together with --file"
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
  if [[ "$FILE_MODE_KIND" == "source" ]]; then
    REPORT_SOURCE="hybrid"
  else
    REPORT_SOURCE="web"
  fi
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

# Avoid mixed Bedrock auth modes in one process.
# Default strategy: if static AWS credentials are present, use them and ignore bearer key.
if [[ "$HAS_BEARER" -eq 1 && "$HAS_AWS_CREDS" -eq 1 ]]; then
  if [[ "${BEDROCK_AUTH_MODE:-aws}" == "bearer" ]]; then
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
    HAS_AWS_CREDS=0
    echo "Both Bedrock auth modes are set; using bearer token (BEDROCK_AUTH_MODE=bearer)."
  else
    unset AWS_BEARER_TOKEN_BEDROCK
    HAS_BEARER=0
    echo "Both Bedrock auth modes are set; using AWS credentials (default)."
  fi
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

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOGS_DIR/${RUN_ID}-research.log"
HYBRID_TIMEOUT_SECONDS="${HYBRID_TIMEOUT_SECONDS:-900}"
WEB_TIMEOUT_SECONDS="${WEB_TIMEOUT_SECONDS:-480}"
REPORT_TYPE="${REPORT_TYPE:-deep}"
DEEP_RESEARCH_BREADTH="${DEEP_RESEARCH_BREADTH:-4}"
DEEP_RESEARCH_DEPTH="${DEEP_RESEARCH_DEPTH:-2}"
DEEP_RESEARCH_CONCURRENCY="${DEEP_RESEARCH_CONCURRENCY:-4}"
export REPORT_TYPE DEEP_RESEARCH_BREADTH DEEP_RESEARCH_DEPTH DEEP_RESEARCH_CONCURRENCY

log_ts() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$RUN_LOG"
}

phase_start() {
  local phase="$1"
  local now
  now="$(date +%s)"
  eval "PHASE_${phase}_START=${now}"
  log_ts "phase_start name=${phase}"
}

phase_done() {
  local phase="$1"
  local reason="${2:-success}"
  local now start_var start dur
  now="$(date +%s)"
  start_var="PHASE_${phase}_START"
  start="${!start_var:-$now}"
  dur=$((now - start))
  log_ts "phase_done name=${phase} duration_s=${dur} reason=${reason}"
}

exit_reason() {
  local code="${1:-1}"
  if [[ "$code" -eq 0 ]]; then
    echo "success"
  elif [[ "$code" -eq 124 ]]; then
    echo "timeout"
  else
    echo "error_exit_${code}"
  fi
}

if [[ "$FILE_MODE" -eq 1 ]]; then
  phase_start "seed_query_from_file"
  export INPUT_FILE
  if [[ "$FILE_MODE_KIND" == "source" ]]; then
    TEMP_DOC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-research-docs.XXXXXX")"
    trap '[[ -n "${TEMP_DOC_DIR:-}" && -d "$TEMP_DOC_DIR" ]] && rm -rf "$TEMP_DOC_DIR"' EXIT
    export TEMP_DOC_DIR
    export HYBRID_DOC_MAX_CHARS="${HYBRID_DOC_MAX_CHARS:-45000}"
    python - <<'PY'
import os
import re
from pathlib import Path

source = Path(os.environ["INPUT_FILE"])
target_dir = Path(os.environ["TEMP_DOC_DIR"])
max_chars = int(os.getenv("HYBRID_DOC_MAX_CHARS", "45000"))

text = source.read_text(encoding="utf-8", errors="replace")
text = text.replace("\r\n", "\n")

def compact_markdown(md: str, limit: int) -> str:
    if len(md) <= limit:
        return md

    lines = md.splitlines()
    selected = []

    # Keep headings and short list-like statements as semantic anchors.
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        if s.startswith("#") or s.startswith("- ") or s.startswith("* ") or re.match(r"^\d+\.\s+", s):
            selected.append(s)
        elif len(s) <= 180 and ":" in s:
            selected.append(s)

    compact = "\n".join(selected)
    if len(compact) < 3000:
        # Fallback: keep first part of the file if structure is sparse.
        compact = md[:limit]
    if len(compact) > limit:
        compact = compact[:limit]
    return compact

compacted = compact_markdown(text, max_chars)

target = target_dir / f"{source.stem}.md"
target.write_text(compacted.strip() + "\n", encoding="utf-8")
print(f"Hybrid local context prepared: {target} ({len(compacted)} chars)")
PY

    export DOC_PATH="$TEMP_DOC_DIR"
  fi
  export FILE_TASK FILE_MODE_KIND

  echo "Preparing ${FILE_MODE_KIND} research query from: $INPUT_FILE"
  export MAX_WEB_QUERY_CHARS="${MAX_WEB_QUERY_CHARS:-360}"
  QUERY="$(python - <<'PY'
import os
import re
from pathlib import Path
import boto3

region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
model_id = os.getenv("SMART_LLM", "")
if model_id.startswith("bedrock:"):
    model_id = model_id.split(":", 1)[1]

source = Path(os.environ["INPUT_FILE"])
content = source.read_text(encoding="utf-8", errors="replace")
file_task = os.getenv("FILE_TASK", "").strip()
mode = os.getenv("FILE_MODE_KIND", "query")
max_chars = int(os.getenv("MAX_WEB_QUERY_CHARS", "520"))

if mode == "source":
    mode_note = (
        "The task will be used as a web-search seed. The full markdown file "
        "is loaded separately as local context via DOC_PATH, so do not restate the brief."
    )
else:
    mode_note = (
        "The markdown file is NOT loaded as local context. Build a compact but "
        "self-sufficient web research task from the brief content."
    )

prompt = f"""
Create a short English web-research task for GPT Researcher based on this markdown brief.

{mode_note}

Rules:
- 180 to 320 characters;
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
query = re.sub(r"\s+", " ", query).strip()

if len(query) > max_chars:
    compress_prompt = (
        f"Compress this web-research task to 180-{max_chars} characters. "
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
    query = re.sub(r"\s+", " ", query).strip()

if len(query) > max_chars:
    cut = query[:max_chars]
    last_period = max(cut.rfind("."), cut.rfind(";"))
    query = cut[:last_period + 1] if last_period > 180 else cut.rstrip()

if len(query) < 80:
    fallback = (file_task or source.stem).strip()
    fallback = re.sub(r"\s+", " ", fallback)
    if len(fallback) > max_chars:
        fallback = fallback[:max_chars].rstrip()
    query = fallback

print(query)
PY
)"
  if [[ -z "$QUERY" ]]; then
    phase_done "seed_query_from_file" "error_empty_query"
    echo "Error: generated research query is empty"
    exit 1
  fi
  echo "Generated web research seed:"
  echo "$QUERY"
  if [[ "$FILE_MODE_KIND" == "source" ]]; then
    echo "Legacy source mode enabled: file is loaded into DOC_PATH."
    echo "Hybrid DOC_PATH: $DOC_PATH"
  else
    echo "Query mode: markdown brief used only to build web query (DOC_PATH disabled)."
  fi
  phase_done "seed_query_from_file" "success"
fi

{
  echo "run_id=$RUN_ID"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "report_source=$REPORT_SOURCE"
  echo "file_mode=${FILE_MODE}"
  echo "file_mode_kind=${FILE_MODE_KIND}"
  echo "verify_brief=${VERIFY_BRIEF}"
  echo "translate_to_ru=$TRANSLATE_TO_RU"
  echo "input_file=${INPUT_FILE:-}"
  echo "doc_path=${DOC_PATH:-}"
  echo "query_chars=${#QUERY}"
  echo "report_type=${REPORT_TYPE}"
  echo "deep_research_breadth=${DEEP_RESEARCH_BREADTH}"
  echo "deep_research_depth=${DEEP_RESEARCH_DEPTH}"
  echo "deep_research_concurrency=${DEEP_RESEARCH_CONCURRENCY}"
  echo "query:"
  echo "$QUERY"
  echo
  echo "--- raw output ---"
} >> "$RUN_LOG"
echo "Run log: $RUN_LOG"

RAW_OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-raw.${RUN_ID}.XXXXXX")"
trap '[[ -n "${TEMP_DOC_DIR:-}" && -d "$TEMP_DOC_DIR" ]] && rm -rf "$TEMP_DOC_DIR"; [[ -n "${RAW_OUTPUT_FILE:-}" && -f "$RAW_OUTPUT_FILE" ]] && rm -f "$RAW_OUTPUT_FILE"' EXIT

run_cli_with_timeout() {
  local source="$1"
  local timeout_sec="$2"
  python - "$APP_DIR" "$QUERY" "$source" "$timeout_sec" "$RAW_OUTPUT_FILE" <<'PY'
import subprocess
import sys
import os
from pathlib import Path

app_dir, query, source, timeout_sec, raw_file = sys.argv[1:]
timeout_sec = int(timeout_sec)
cmd = [
    sys.executable, "cli.py", query,
    "--report_type", os.environ.get("REPORT_TYPE", "deep"),
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
  phase_start "research_hybrid"
  log_ts "hybrid_start timeout=${HYBRID_TIMEOUT_SECONDS}s"
  if run_cli_with_timeout "hybrid" "$HYBRID_TIMEOUT_SECONDS"; then
    RUN_EXIT=0
    EXEC_SOURCE="hybrid"
    log_ts "hybrid_success"
    phase_done "research_hybrid" "success"
  else
    RUN_EXIT=$?
    phase_done "research_hybrid" "$(exit_reason "$RUN_EXIT")"
    log_ts "hybrid_failed exit_code=$RUN_EXIT fallback=web"
    phase_start "research_web_fallback"
    log_ts "web_fallback_start timeout=${WEB_TIMEOUT_SECONDS}s"
    if run_cli_with_timeout "web" "$WEB_TIMEOUT_SECONDS"; then
      RUN_EXIT=0
      EXEC_SOURCE="web"
      log_ts "web_fallback_success"
      phase_done "research_web_fallback" "success"
    else
      RUN_EXIT=$?
      log_ts "web_fallback_failed exit_code=$RUN_EXIT"
      phase_done "research_web_fallback" "$(exit_reason "$RUN_EXIT")"
    fi
  fi
else
  phase_start "research_web"
  log_ts "web_start timeout=${WEB_TIMEOUT_SECONDS}s"
  if run_cli_with_timeout "web" "$WEB_TIMEOUT_SECONDS"; then
    RUN_EXIT=0
    EXEC_SOURCE="web"
    log_ts "web_success"
    phase_done "research_web" "success"
  else
    RUN_EXIT=$?
    log_ts "web_failed exit_code=$RUN_EXIT"
    phase_done "research_web" "$(exit_reason "$RUN_EXIT")"
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
  phase_start "translation_ru"
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
  phase_done "translation_ru" "success"
else
  log_ts "translation_skip mode=en"
  phase_done "translation_ru" "skipped_en"
  DEST_REPORT="${BASE_REPORT_PATH}.md"
  cp "$SRC_REPORT" "$DEST_REPORT"
  echo "Saved report: $DEST_REPORT"
fi

if [[ "$FILE_MODE" -eq 1 && "$VERIFY_BRIEF" -eq 1 ]]; then
  phase_start "brief_verification"
  log_ts "brief_verification_start mode=${FILE_MODE_KIND}"
  export DEST_REPORT INPUT_FILE
  export VERIFY_MAX_CLAIMS="${VERIFY_MAX_CLAIMS:-8}"
  export VERIFY_MAX_RESULTS="${VERIFY_MAX_RESULTS:-5}"
  if python - <<'PY'
import json
import os
import re
import urllib.error
import urllib.request
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError

report_path = Path(os.environ["DEST_REPORT"])
input_path = Path(os.environ["INPUT_FILE"])
api_key = os.getenv("TAVILY_API_KEY", "").strip()
max_claims = max(1, int(os.getenv("VERIFY_MAX_CLAIMS", "8")))
max_results = max(1, min(10, int(os.getenv("VERIFY_MAX_RESULTS", "5"))))
region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
model_id = os.getenv("SMART_LLM", "")
if model_id.startswith("bedrock:"):
    model_id = model_id.split(":", 1)[1]

if not report_path.exists():
    print(f"Warning: report not found for verification: {report_path}")
    raise SystemExit(0)
if not input_path.exists():
    print(f"Warning: input brief not found for verification: {input_path}")
    raise SystemExit(0)
if not api_key:
    print("Warning: TAVILY_API_KEY missing; skipping brief verification")
    raise SystemExit(0)

brief_text = input_path.read_text(encoding="utf-8", errors="replace").strip()
if not brief_text:
    print("Warning: empty brief file; skipping verification")
    raise SystemExit(0)

client = boto3.client("bedrock-runtime", region_name=region)

def llm(prompt: str, max_tokens: int = 1800) -> str:
    resp = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": max_tokens, "temperature": 0},
    )
    return resp["output"]["message"]["content"][0]["text"].strip()

def parse_json_from_text(text: str):
    try:
        return json.loads(text)
    except Exception:
        pass
    match = re.search(r"(\{.*\}|\[.*\])", text, flags=re.S)
    if match:
        try:
            return json.loads(match.group(1))
        except Exception:
            return None
    return None

def extract_claims(text: str):
    prompt = f"""
Extract up to {max_claims} factual claims from this markdown brief.

Rules:
- Return strict JSON array only: [{{"claim":"..."}}]
- Include only claims that can be checked against external web sources.
- Ignore preferences, style notes, and questions.
- Keep each claim concise and specific.

Markdown brief:
{text}
"""
    raw = llm(prompt, max_tokens=1200)
    payload = parse_json_from_text(raw)
    claims = []
    if isinstance(payload, list):
        for item in payload:
            if isinstance(item, dict):
                claim = str(item.get("claim", "")).strip()
            else:
                claim = str(item).strip()
            if claim:
                claims.append(claim)
    deduped = []
    seen = set()
    for claim in claims:
        key = re.sub(r"\s+", " ", claim).strip().lower()
        if key and key not in seen:
            seen.add(key)
            deduped.append(claim)
    return deduped[:max_claims]

def tavily_search(query: str):
    body = json.dumps(
        {
            "query": query,
            "search_depth": "basic",
            "max_results": max_results,
            "include_answer": False,
            "include_raw_content": False,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        "https://api.tavily.com/search",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )
    with urllib.request.urlopen(req, timeout=40) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    return data.get("results") or []

def evaluate_claim(claim: str, results: list[dict]):
    evidence_chunks = []
    cleaned_results = []
    for idx, result in enumerate(results, start=1):
        url = str(result.get("url") or result.get("href") or "").strip()
        title = str(result.get("title") or "").strip()
        snippet = str(result.get("content") or result.get("body") or "").strip()
        if not url:
            continue
        cleaned_results.append({"url": url, "title": title, "snippet": snippet})
        evidence_chunks.append(
            f"[{idx}] URL: {url}\nTitle: {title or 'n/a'}\nSnippet: {snippet[:700] or 'n/a'}"
        )

    if not cleaned_results:
        return {
            "status": "unverified",
            "note": "No external evidence was retrieved for this claim.",
            "evidence_url": "n/a",
        }

    prompt = f"""
Fact-check exactly one claim using only the external evidence snippets below.

Claim:
{claim}

External evidence:
{chr(10).join(evidence_chunks)}

Rules:
- The brief itself is NOT evidence.
- Use only snippets and URLs above.
- status=verified: evidence clearly supports claim, no major contradiction.
- status=conflicting: evidence contradicts claim or gives mixed signals.
- status=unverified: evidence is insufficient to confirm or deny.

Return strict JSON only:
{{
  "status": "verified|conflicting|unverified",
  "note": "short reason",
  "evidence_index": <number or null>
}}
"""
    raw = llm(prompt, max_tokens=700)
    payload = parse_json_from_text(raw)
    status = "unverified"
    note = "Insufficient external evidence."
    evidence_url = "n/a"
    if isinstance(payload, dict):
        cand_status = str(payload.get("status", "")).strip().lower()
        if cand_status in {"verified", "conflicting", "unverified"}:
            status = cand_status
        cand_note = str(payload.get("note", "")).strip()
        if cand_note:
            note = cand_note
        index = payload.get("evidence_index")
        if isinstance(index, int) and 1 <= index <= len(cleaned_results):
            evidence_url = cleaned_results[index - 1]["url"]
    if evidence_url == "n/a":
        evidence_url = cleaned_results[0]["url"]
    return {"status": status, "note": note, "evidence_url": evidence_url}

def esc_cell(value: str) -> str:
    text = str(value or "").replace("\n", " ").replace("\r", " ").strip()
    text = re.sub(r"\s+", " ", text)
    return text.replace("|", "\\|")

rows = []
try:
    claims = extract_claims(brief_text)
except (ClientError, BotoCoreError, Exception) as e:
    claims = []
    rows.append(
        {
            "claim": "n/a",
            "status": "unverified",
            "url": "n/a",
            "note": f"Claim extraction failed: {e}",
        }
    )

for claim in claims:
    try:
        results = tavily_search(claim)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, Exception) as e:
        rows.append(
            {
                "claim": claim,
                "status": "unverified",
                "url": "n/a",
                "note": f"Search error: {e}",
            }
        )
        continue
    try:
        verdict = evaluate_claim(claim, results)
    except (ClientError, BotoCoreError, Exception) as e:
        verdict = {
            "status": "unverified",
            "note": f"Evaluation error: {e}",
            "evidence_url": (results[0].get("url") if results else "n/a"),
        }
    rows.append(
        {
            "claim": claim,
            "status": verdict["status"],
            "url": verdict["evidence_url"],
            "note": verdict["note"],
        }
    )

if not rows:
    rows.append(
        {
            "claim": "n/a",
            "status": "unverified",
            "url": "n/a",
            "note": "No factual claims were extracted from the brief.",
        }
    )

section = [
    "## Brief Claim Verification",
    "",
    "_External URLs are the only evidence source; brief text is not treated as evidence._",
    "",
    "| Claim | Status | Evidence URL | Note |",
    "|---|---|---|---|",
]
for row in rows:
    section.append(
        "| "
        + esc_cell(row["claim"])
        + " | "
        + esc_cell(row["status"])
        + " | "
        + esc_cell(row["url"])
        + " | "
        + esc_cell(row["note"])
        + " |"
    )

report_text = report_path.read_text(encoding="utf-8", errors="replace").rstrip()
section_text = "\n".join(section).rstrip()
if "## Brief Claim Verification" in report_text:
    report_text = re.sub(
        r"\n## Brief Claim Verification[\s\S]*$",
        "",
        report_text,
        flags=re.M,
    ).rstrip()

report_path.write_text(report_text + "\n\n" + section_text + "\n", encoding="utf-8")
print(f"Brief verification rows: {len(rows)}")
PY
  then
    log_ts "brief_verification_done"
    phase_done "brief_verification" "success"
  else
    verify_exit=$?
    log_ts "brief_verification_failed exit_code=${verify_exit}"
    phase_done "brief_verification" "$(exit_reason "$verify_exit")"
  fi
elif [[ "$FILE_MODE" -eq 1 ]]; then
  phase_done "brief_verification" "skipped_disabled"
fi

{
  echo "saved_report=$DEST_REPORT"
  echo "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$RUN_LOG"
echo "Saved log: $RUN_LOG"
