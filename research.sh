#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/gpt-researcher"
REPORTS_DIR="$HOME/Downloads"
ENV_FILE="$ROOT_DIR/.env"
LOGS_DIR="$ROOT_DIR/logs"
SCRIPTS_DIR="$ROOT_DIR/scripts"
PREFILTER_SCRIPT="$SCRIPTS_DIR/prefilter_query.py"
RUN_CLI_SCRIPT="$SCRIPTS_DIR/run_research_cli.py"
TRANSLATE_SCRIPT="$SCRIPTS_DIR/translate_report_ru.py"
LOCK_DIR="$ROOT_DIR/.research.lock.d"
LOCK_META_FILE="$ROOT_DIR/.research.lock.meta"

print_usage() {
  echo "Usage: ./research.sh [--ru] [--yes|--no-confirm|--confirm] [--prefilter-only] [--from-prefilter /path/prefilter.json] [--file /path/input.txt|.md] \"/path/notes.md\" | \"topic or raw dump\""
  echo "Default: deep research with an English final report. Use `--ru` to translate the final report to Russian."
  echo "Legacy compatibility: `--deep`, `--en`, and `--no-translate` are still accepted."
}

if [[ $# -lt 1 ]]; then
  print_usage
  exit 1
fi

TRANSLATE_TO_RU=0
LEGACY_LANGUAGE_FLAG=""
CONFIRM_BEFORE_RESEARCH=auto
PREFILTER_ONLY=0
FROM_PREFILTER=""
INPUT_FILE=""
DEEP_MODE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ru)
      TRANSLATE_TO_RU=1
      shift
      ;;
    --en)
      LEGACY_LANGUAGE_FLAG="--en"
      TRANSLATE_TO_RU=0
      shift
      ;;
    --no-translate)
      LEGACY_LANGUAGE_FLAG="--no-translate"
      TRANSLATE_TO_RU=0
      shift
      ;;
    --yes|--no-confirm)
      CONFIRM_BEFORE_RESEARCH=no
      shift
      ;;
    --confirm)
      CONFIRM_BEFORE_RESEARCH=yes
      shift
      ;;
    --prefilter-only)
      PREFILTER_ONLY=1
      CONFIRM_BEFORE_RESEARCH=no
      shift
      ;;
    --deep)
      DEEP_MODE=1
      shift
      ;;
    --from-prefilter)
      if [[ $# -lt 2 ]]; then
        echo "Error: --from-prefilter requires a path"
        exit 1
      fi
      FROM_PREFILTER="$2"
      CONFIRM_BEFORE_RESEARCH=no
      shift 2
      ;;
    --file)
      if [[ $# -lt 2 ]]; then
        echo "Error: --file requires a path"
        exit 1
      fi
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

QUERY_RAW="$*"
if [[ -n "$FROM_PREFILTER" && ( -n "$INPUT_FILE" || -n "$QUERY_RAW" ) ]]; then
  echo "Error: --from-prefilter cannot be combined with a new query or --file"
  exit 1
fi
if [[ -z "$INPUT_FILE" && "$#" -eq 1 && -f "$1" && "$1" == *.md ]]; then
  INPUT_FILE="$1"
  QUERY_RAW=""
fi
if [[ -z "$FROM_PREFILTER" && -z "$INPUT_FILE" && -z "$QUERY_RAW" ]]; then
  print_usage
  exit 1
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

for script in "$PREFILTER_SCRIPT" "$RUN_CLI_SCRIPT" "$TRANSLATE_SCRIPT"; do
  if [[ ! -f "$script" ]]; then
    echo "Error: helper script missing: $script"
    exit 1
  fi
done

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "Error: TAVILY_API_KEY is missing in .env"
  exit 1
fi

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

if [[ -z "${AWS_DEFAULT_REGION:-}" && -z "${AWS_REGION:-}" ]]; then
  echo "Error: set AWS_DEFAULT_REGION (or AWS_REGION) in .env"
  exit 1
fi

ENV_REPORT_TYPE="${REPORT_TYPE:-}"
ENV_DEEP_RESEARCH_BREADTH="${DEEP_RESEARCH_BREADTH:-}"
ENV_DEEP_RESEARCH_DEPTH="${DEEP_RESEARCH_DEPTH:-}"
ENV_DEEP_RESEARCH_CONCURRENCY="${DEEP_RESEARCH_CONCURRENCY:-}"
ENV_SOFT_LIMIT_ENABLED="${SOFT_LIMIT_ENABLED:-}"
ENV_SOFT_LIMIT_TAVILY_CALLS="${SOFT_LIMIT_TAVILY_CALLS:-}"
ENV_SOFT_LIMIT_BEDROCK_TOTAL_TOKENS="${SOFT_LIMIT_BEDROCK_TOTAL_TOKENS:-}"
ENV_SOFT_LIMIT_ELAPSED_SECONDS="${SOFT_LIMIT_ELAPSED_SECONDS:-}"
ENV_SOFT_LIMIT_MAX_SUBQUERIES="${SOFT_LIMIT_MAX_SUBQUERIES:-}"

REPORT_TYPE="${ENV_REPORT_TYPE:-research_report}"
DEEP_RESEARCH_BREADTH="${ENV_DEEP_RESEARCH_BREADTH:-4}"
DEEP_RESEARCH_DEPTH="${ENV_DEEP_RESEARCH_DEPTH:-2}"
DEEP_RESEARCH_CONCURRENCY="${ENV_DEEP_RESEARCH_CONCURRENCY:-4}"
WEB_TIMEOUT_SECONDS="${WEB_TIMEOUT_SECONDS:-1200}"
SOFT_LIMIT_ENABLED="${ENV_SOFT_LIMIT_ENABLED:-1}"
SOFT_LIMIT_TAVILY_CALLS="${ENV_SOFT_LIMIT_TAVILY_CALLS:-25}"
SOFT_LIMIT_BEDROCK_TOTAL_TOKENS="${ENV_SOFT_LIMIT_BEDROCK_TOTAL_TOKENS:-300000}"
SOFT_LIMIT_ELAPSED_SECONDS="${ENV_SOFT_LIMIT_ELAPSED_SECONDS:-600}"
SOFT_LIMIT_MAX_SUBQUERIES="${ENV_SOFT_LIMIT_MAX_SUBQUERIES:-12}"

if [[ "$DEEP_MODE" -eq 1 ]]; then
  REPORT_TYPE="deep"

  # Default deep profile chosen from local comparison runs:
  # wider first pass outperformed extra recursion on the same topic.
  if [[ -z "$ENV_DEEP_RESEARCH_BREADTH" ]]; then
    DEEP_RESEARCH_BREADTH=4
  fi
  if [[ -z "$ENV_DEEP_RESEARCH_DEPTH" ]]; then
    DEEP_RESEARCH_DEPTH=2
  fi
  if [[ -z "$ENV_DEEP_RESEARCH_CONCURRENCY" ]]; then
    DEEP_RESEARCH_CONCURRENCY=4
  fi
  if [[ -z "$ENV_SOFT_LIMIT_TAVILY_CALLS" ]]; then
    SOFT_LIMIT_TAVILY_CALLS=14
  fi
  if [[ -z "$ENV_SOFT_LIMIT_BEDROCK_TOTAL_TOKENS" ]]; then
    SOFT_LIMIT_BEDROCK_TOTAL_TOKENS=160000
  fi
  if [[ -z "$ENV_SOFT_LIMIT_ELAPSED_SECONDS" ]]; then
    SOFT_LIMIT_ELAPSED_SECONDS=540
  fi
  if [[ -z "$ENV_SOFT_LIMIT_MAX_SUBQUERIES" ]]; then
    SOFT_LIMIT_MAX_SUBQUERIES=8
  fi
fi

RUN_STARTED_AT_EPOCH="$(date +%s)"
export REPORT_TYPE DEEP_RESEARCH_BREADTH DEEP_RESEARCH_DEPTH DEEP_RESEARCH_CONCURRENCY
export SOFT_LIMIT_ENABLED SOFT_LIMIT_TAVILY_CALLS SOFT_LIMIT_BEDROCK_TOTAL_TOKENS SOFT_LIMIT_ELAPSED_SECONDS SOFT_LIMIT_MAX_SUBQUERIES RUN_STARTED_AT_EPOCH

mkdir -p "$REPORTS_DIR" "$LOGS_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOGS_DIR/${RUN_ID}-research.log"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -f "$LOCK_META_FILE" ]]; then
    echo "Error: another research run is already in progress."
    cat "$LOCK_META_FILE"
  else
    echo "Error: another research run is already in progress."
  fi
  exit 16
fi

cleanup_lock_meta() {
  rm -rf "$LOCK_DIR"
  rm -f "$LOCK_META_FILE"
}
trap cleanup_lock_meta EXIT

log_ts() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$RUN_LOG"
}

write_prefilter_artifact() {
  local artifact_path="$1"
  local input_mode="$2"
  local input_file="$3"
  python3 - "$artifact_path" "$RUN_ID" "$RUN_LOG" "$PREFILTER_BRIEF_FILE" "$PREFILTER_QUERY_FILE" "$QUERY" "$input_mode" "$input_file" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

artifact_path = Path(sys.argv[1])
payload = {
    "version": 1,
    "prefilter_run_id": sys.argv[2],
    "created_at_utc": datetime.now(timezone.utc).isoformat(),
    "prefilter_log_path": sys.argv[3],
    "brief_path": sys.argv[4],
    "query_path": sys.argv[5],
    "normalized_query": sys.argv[6],
    "input_mode": sys.argv[7],
    "input_file": sys.argv[8],
}
artifact_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

load_prefilter_artifact() {
  local artifact_path="$1"
  local resolved
  resolved="$(python3 - "$artifact_path" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve())
PY
)"
  if [[ ! -f "$resolved" ]]; then
    echo "Error: prefilter artifact not found: $resolved"
    exit 1
  fi

  eval "$(python3 - "$resolved" <<'PY'
import json
import shlex
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
fields = {
    "PREFILTER_SOURCE_RUN_ID": data.get("prefilter_run_id", ""),
    "QUERY": data.get("normalized_query", ""),
    "PREFILTER_BRIEF_FILE": data.get("brief_path", ""),
    "PREFILTER_QUERY_FILE": data.get("query_path", ""),
    "PREFILTER_INPUT_MODE": data.get("input_mode", "inline_text"),
    "PREFILTER_INPUT_FILE": data.get("input_file", ""),
    "PREFILTER_SOURCE_LOG": data.get("prefilter_log_path", ""),
}
for key, value in fields.items():
    clean = str(value).replace("\n", " ").replace("\r", " ")
    print(f"{key}={shlex.quote(clean)}")
PY
)"
  PREFILTER_SOURCE_ARTIFACT="$resolved"

  if [[ -z "$QUERY" || -z "$PREFILTER_BRIEF_FILE" ]]; then
    echo "Error: invalid prefilter artifact: $resolved"
    exit 1
  fi
  if [[ ! -f "$PREFILTER_BRIEF_FILE" ]]; then
    echo "Error: prefilter brief not found: $PREFILTER_BRIEF_FILE"
    exit 1
  fi
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

if [[ -n "$INPUT_FILE" ]]; then
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
fi

RAW_INPUT_FILE=""
PREFILTER_QUERY_FILE=""
PREFILTER_BRIEF_FILE=""
RAW_OUTPUT_FILE=""
PREFILTER_ARTIFACT_FILE=""
PREFILTER_SOURCE_ARTIFACT=""
PREFILTER_SOURCE_RUN_ID=""
PREFILTER_SOURCE_LOG=""
PREFILTER_INPUT_MODE=""
PREFILTER_INPUT_FILE=""

if [[ -z "$FROM_PREFILTER" ]]; then
  RAW_INPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-raw-input.${RUN_ID}.XXXXXX")"
  PREFILTER_QUERY_FILE="$LOGS_DIR/${RUN_ID}-prefilter-query.txt"
  PREFILTER_BRIEF_FILE="$LOGS_DIR/${RUN_ID}-prefilter-brief.md"
  RAW_OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-raw.${RUN_ID}.XXXXXX")"
  trap 'cleanup_lock_meta; [[ -n "$RAW_INPUT_FILE" && -f "$RAW_INPUT_FILE" ]] && rm -f "$RAW_INPUT_FILE"; [[ -n "$RAW_OUTPUT_FILE" && -f "$RAW_OUTPUT_FILE" ]] && rm -f "$RAW_OUTPUT_FILE"' EXIT

  if [[ -n "$INPUT_FILE" ]]; then
    cat "$INPUT_FILE" > "$RAW_INPUT_FILE"
  else
    printf '%s\n' "$QUERY_RAW" > "$RAW_INPUT_FILE"
  fi
else
  RAW_OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-raw.${RUN_ID}.XXXXXX")"
  trap 'cleanup_lock_meta; [[ -n "$RAW_OUTPUT_FILE" && -f "$RAW_OUTPUT_FILE" ]] && rm -f "$RAW_OUTPUT_FILE"' EXIT
  load_prefilter_artifact "$FROM_PREFILTER"
fi

{
  echo "run_id=$RUN_ID"
  echo "pid=$$"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "cwd=$ROOT_DIR"
  echo "log=$RUN_LOG"
} > "$LOCK_META_FILE"

if [[ -n "$LEGACY_LANGUAGE_FLAG" ]]; then
  echo "Legacy compatibility: $LEGACY_LANGUAGE_FLAG keeps the final report in English. English output is already the default."
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

try:
    runtime = boto3.client("bedrock-runtime", region_name=region)
    runtime.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": "ping"}]}],
        inferenceConfig={"maxTokens": 1, "temperature": 0},
    )
except ClientError as e:
    code = e.response.get("Error", {}).get("Code", "Unknown")
    msg = e.response.get("Error", {}).get("Message", str(e))
    print(f"Bedrock check failed: {code} - {msg}")
    sys.exit(2)
except BotoCoreError as e:
    print(f"Bedrock check failed: {e}")
    sys.exit(2)
except Exception as e:
    print(f"Bedrock check failed: {e}")
    sys.exit(2)
PY

echo "Bedrock check passed for model: $BEDROCK_MODEL_ID"

if [[ -z "$FROM_PREFILTER" ]]; then
  phase_start "prefilter"
  PREFILTER_INPUT_MODE="$( [[ -n "$INPUT_FILE" ]] && echo file_as_query || echo inline_text )"
  PREFILTER_INPUT_FILE="${INPUT_FILE:-}"
  log_ts "prefilter_start input=$PREFILTER_INPUT_MODE"
  python "$PREFILTER_SCRIPT" "$RAW_INPUT_FILE" "$PREFILTER_BRIEF_FILE" "$PREFILTER_QUERY_FILE" | tee -a "$RUN_LOG"

  QUERY="$(tr -d '\r' < "$PREFILTER_QUERY_FILE" | head -n 1 | sed 's/[[:space:]]\+$//')"
  if [[ -z "$QUERY" ]]; then
    phase_done "prefilter" "error_empty_query"
    echo "Error: prefilter produced empty query"
    exit 1
  fi

  echo "Generated web research query:"
  echo "$QUERY"
  echo "Prefilter brief saved: $PREFILTER_BRIEF_FILE"
  phase_done "prefilter" "success"

  PREFILTER_ARTIFACT_FILE="$LOGS_DIR/${RUN_ID}-prefilter.json"
  write_prefilter_artifact "$PREFILTER_ARTIFACT_FILE" "$PREFILTER_INPUT_MODE" "$PREFILTER_INPUT_FILE"

  if [[ "$PREFILTER_ONLY" -eq 1 ]]; then
    echo "Prefilter artifact saved: $PREFILTER_ARTIFACT_FILE"
    echo "Normalized brief: $PREFILTER_BRIEF_FILE"
    echo "Run log: $RUN_LOG"
    echo "STATUS: prefilter_ready"
    echo "PREFILTER_ARTIFACT: $PREFILTER_ARTIFACT_FILE"
    echo "PREFILTER_BRIEF: $PREFILTER_BRIEF_FILE"
    echo "PREFILTER_QUERY: $QUERY"
    echo "PREFILTER_INPUT_MODE: $PREFILTER_INPUT_MODE"
    echo "PREFILTER_RUN_LOG: $RUN_LOG"
    exit 0
  fi
else
  echo "Loaded prefilter artifact: $PREFILTER_SOURCE_ARTIFACT"
  echo "Generated web research query:"
  echo "$QUERY"
  echo "Prefilter brief saved: $PREFILTER_BRIEF_FILE"
fi

confirm_research_start() {
  local reply
  local mode="$1"

  if [[ "$mode" == "no" ]]; then
    log_ts "prefilter_confirm skip=flag"
    return 0
  fi

  if [[ "$mode" == "auto" && ! -t 0 ]]; then
    log_ts "prefilter_confirm skip=non_interactive"
    return 0
  fi

  echo
  echo "Normalized brief:"
  sed -n '1,80p' "$PREFILTER_BRIEF_FILE"
  echo
  echo "Normalized web query:"
  echo "$QUERY"
  echo

  while true; do
    printf "Start research with this query? [Y/n/e]: "
    IFS= read -r reply
    reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]' | xargs)"

    case "$reply" in
      ""|y|yes)
        log_ts "prefilter_confirm answer=yes"
        return 0
        ;;
      n|no)
        log_ts "prefilter_confirm answer=no"
        echo "Cancelled before web research."
        exit 12
        ;;
      e|edit)
        log_ts "prefilter_confirm answer=edit"
        echo "Edit your request and run the command again."
        exit 13
        ;;
      *)
        echo "Please answer y, n, or e."
        ;;
    esac
  done
}

confirm_research_start "$CONFIRM_BEFORE_RESEARCH"

{
  echo "run_id=$RUN_ID"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mode=$( [[ -n "$FROM_PREFILTER" ]] && echo from_prefilter || echo web_only )"
  echo "report_source=web"
  echo "input_mode=${PREFILTER_INPUT_MODE:-$( [[ -n "$INPUT_FILE" ]] && echo file_as_query || echo inline_text )}"
  echo "input_file=${PREFILTER_INPUT_FILE:-${INPUT_FILE:-}}"
  echo "prefilter_brief=$PREFILTER_BRIEF_FILE"
  echo "prefilter_query_file=${PREFILTER_QUERY_FILE:-}"
  echo "prefilter_artifact=${PREFILTER_ARTIFACT_FILE:-$PREFILTER_SOURCE_ARTIFACT}"
  echo "prefilter_source_run_id=${PREFILTER_SOURCE_RUN_ID:-$RUN_ID}"
  echo "prefilter_source_log=${PREFILTER_SOURCE_LOG:-$RUN_LOG}"
  echo "web_timeout_seconds=$WEB_TIMEOUT_SECONDS"
  echo "report_type=$REPORT_TYPE"
  echo "deep_research_breadth=$DEEP_RESEARCH_BREADTH"
  echo "deep_research_depth=$DEEP_RESEARCH_DEPTH"
  echo "deep_research_concurrency=$DEEP_RESEARCH_CONCURRENCY"
  echo "soft_limit_enabled=$SOFT_LIMIT_ENABLED"
  echo "soft_limit_tavily_calls=$SOFT_LIMIT_TAVILY_CALLS"
  echo "soft_limit_bedrock_total_tokens=$SOFT_LIMIT_BEDROCK_TOTAL_TOKENS"
  echo "soft_limit_elapsed_seconds=$SOFT_LIMIT_ELAPSED_SECONDS"
  echo "soft_limit_max_subqueries=$SOFT_LIMIT_MAX_SUBQUERIES"
  echo "query_chars=${#QUERY}"
  echo "query:"
  echo "$QUERY"
  echo
  echo "--- raw output ---"
} >> "$RUN_LOG"
echo "Run log: $RUN_LOG"

run_cli_with_timeout() {
  local timeout_sec="$1"
  python "$RUN_CLI_SCRIPT" "$APP_DIR" "$QUERY" "$timeout_sec" "$RAW_OUTPUT_FILE"
}

phase_start "research_web"
log_ts "web_start timeout=${WEB_TIMEOUT_SECONDS}s"
if run_cli_with_timeout "$WEB_TIMEOUT_SECONDS"; then
  RUN_EXIT=0
  log_ts "web_success"
  phase_done "research_web" "success"
else
  RUN_EXIT=$?
  log_ts "web_failed exit_code=$RUN_EXIT"
  phase_done "research_web" "error_exit_${RUN_EXIT}"
fi

RAW_OUTPUT="$(cat "$RAW_OUTPUT_FILE")"
printf '%s\n' "$RAW_OUTPUT" >> "$RUN_LOG"

if [[ "$RUN_EXIT" -ne 0 ]]; then
  echo "Error: GPT Researcher execution failed"
  exit "$RUN_EXIT"
fi

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
DEST_REPORT="$REPORTS_DIR/${DATE_STR}-${SLUG}.md"

if [[ "$TRANSLATE_TO_RU" -eq 1 ]]; then
  phase_start "translation_ru"
  log_ts "translation_start mode=ru"
  python "$TRANSLATE_SCRIPT" "$SRC_REPORT" "$DEST_REPORT" | tee -a "$RUN_LOG"
  log_ts "translation_done"
  phase_done "translation_ru" "success"
else
  cp "$SRC_REPORT" "$DEST_REPORT"
  log_ts "translation_skip mode=en"
fi

telemetry_json="$(python3 - "$RUN_LOG" "$RUN_ID" "$REPORT_TYPE" "$FAST_LLM" "$SMART_LLM" "$STRATEGIC_LLM" <<'PY'
import json, re, sys
from datetime import datetime, timezone
from pathlib import Path

log_path = Path(sys.argv[1])
run_id = sys.argv[2]
report_type = sys.argv[3]
fast_llm = sys.argv[4]
smart_llm = sys.argv[5]
strategic_llm = sys.argv[6]
text = log_path.read_text(encoding="utf-8", errors="replace")

def count(pattern: str) -> int:
    return len(re.findall(pattern, text))

def first_match(pattern: str, default: str = "") -> str:
    m = re.search(pattern, text, re.M)
    return m.group(1).strip() if m else default

phase_re = re.compile(r"^(\d{4}-\d{2}-\d{2}T[^ ]+) phase_done name=([a-z_]+) duration_s=([0-9]+) reason=([^\n]+)$", re.M)
phase_durations = {}
for _, name, dur, reason in phase_re.findall(text):
    phase_durations[name] = {"duration_s": int(dur), "reason": reason}

tel_lines = [line for line in text.splitlines() if line.startswith("TELEMETRY_JSON ")]
def blank_usage():
    return {
        "calls": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_write_input_tokens": 0,
        "estimated_cost_usd": 0.0,
    }

bedrock = {
    "calls": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_input_tokens": 0,
    "cache_write_input_tokens": 0,
    "estimated_cost_usd": 0.0,
}
bedrock_by_stage = {
    "prefilter": blank_usage(),
    "research": blank_usage(),
    "translation": blank_usage(),
}
bedrock_by_step = {}
bedrock_by_model = {}
tavily = {
    "calls_dedup": 0,
    "failed_calls": 0,
    "estimated_credits": 0.0,
}
soft_limit = {"triggered": False, "reason": ""}

def bedrock_rate_card(model_name: str):
    m = (model_name or "").lower()
    if "opus" in m:
        return {"input": 5.0, "output": 25.0, "cache_read": 0.5, "cache_write": 6.25}
    if "haiku" in m:
        return {"input": 0.8, "output": 4.0, "cache_read": 0.08, "cache_write": 1.0}
    return {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.75}

def estimate_bedrock_usage_cost(model_name: str, usage: dict) -> float:
    r = bedrock_rate_card(model_name)
    inp = float(usage.get("inputTokens", usage.get("input_tokens", 0)) or 0)
    out = float(usage.get("outputTokens", usage.get("output_tokens", 0)) or 0)
    cr = float(
        usage.get(
            "cacheReadInputTokens",
            usage.get("cache_read_input_tokens", usage.get("input_token_details", {}).get("cache_read", 0)),
        )
        or 0
    )
    cw = float(
        usage.get(
            "cacheWriteInputTokens",
            usage.get("cache_write_input_tokens", usage.get("input_token_details", {}).get("cache_creation", 0)),
        )
        or 0
    )
    return (
        (inp * r["input"])
        + (out * r["output"])
        + (cr * r["cache_read"])
        + (cw * r["cache_write"])
    ) / 1_000_000.0

def normalize_usage(usage: dict) -> tuple[int, int, int, int]:
    inp = int(usage.get("inputTokens", usage.get("input_tokens", 0)) or 0)
    out = int(usage.get("outputTokens", usage.get("output_tokens", 0)) or 0)
    cr = int(
        usage.get(
            "cacheReadInputTokens",
            usage.get("cache_read_input_tokens", usage.get("input_token_details", {}).get("cache_read", 0)),
        )
        or 0
    )
    cw = int(
        usage.get(
            "cacheWriteInputTokens",
            usage.get("cache_write_input_tokens", usage.get("input_token_details", {}).get("cache_creation", 0)),
        )
        or 0
    )
    return inp, out, cr, cw

def usage_bucket(store: dict, key: str):
    if key not in store:
        store[key] = blank_usage()
    return store[key]

def add_usage(target: dict, usage: dict, estimated_cost_usd: float) -> None:
    inp, out, cr, cw = normalize_usage(usage)
    target["calls"] += 1
    target["input_tokens"] += inp
    target["output_tokens"] += out
    target["cache_read_input_tokens"] += cr
    target["cache_write_input_tokens"] += cw
    target["estimated_cost_usd"] += float(estimated_cost_usd or 0.0)

for raw in tel_lines:
    payload = raw[len("TELEMETRY_JSON "):]
    try:
        item = json.loads(payload)
    except Exception:
        continue
    typ = item.get("type")
    if typ == "bedrock_usage":
        usage = item.get("usage", {}) or {}
        event_cost = float(item.get("estimated_cost_usd", 0.0) or 0.0)
        if event_cost <= 0:
            event_cost = estimate_bedrock_usage_cost(item.get("model", ""), usage)
        add_usage(bedrock, usage, event_cost)
        model_key = str(item.get("model", "") or "unknown")
        add_usage(usage_bucket(bedrock_by_model, model_key), usage, event_cost)
    elif typ in ("prefilter_bedrock", "translation_bedrock"):
        usage = item.get("usage", {}) or {}
        model_name = item.get("model", "")
        c = estimate_bedrock_usage_cost(model_name, usage)
        add_usage(bedrock, usage, c)
        stage_key = "prefilter" if typ == "prefilter_bedrock" else "translation"
        add_usage(bedrock_by_stage[stage_key], usage, c)
        add_usage(usage_bucket(bedrock_by_step, stage_key), usage, c)
        add_usage(usage_bucket(bedrock_by_model, model_name or "unknown"), usage, c)
    elif typ == "bedrock_usage_step":
        step_name = str(item.get("step", "research"))
        usage = item.get("usage", {}) or {}
        event_cost = float(item.get("estimated_cost_usd", 0.0) or 0.0)
        add_usage(bedrock_by_stage["research"], usage, event_cost)
        add_usage(usage_bucket(bedrock_by_step, step_name), usage, event_cost)
    elif typ == "tavily_usage":
        # Keep only canonical events from agent runtime and ignore duplicate usage-only events.
        is_canonical = ("success" in item) or ("totals" in item)
        if not is_canonical:
            continue
        tavily["calls_dedup"] += 1
        if item.get("success") is False:
            tavily["failed_calls"] += 1
        usage = item.get("usage", {}) or {}
        req_credits = None
        for credit_key in ("credits_used", "request_credits", "total_credits", "credits"):
            val = usage.get(credit_key)
            if isinstance(val, (int, float)):
                req_credits = float(val)
                break
        if req_credits is not None and req_credits > 0:
            tavily["estimated_credits"] += req_credits
    elif typ == "soft_limit_triggered":
        soft_limit["triggered"] = True
        soft_limit["reason"] = item.get("reason", "")

tavily["calls"] = tavily["calls_dedup"]
pre_filter_usage_calls = count(r'"type": "prefilter_bedrock"')
translation_calls = count(r'"type": "translation_bedrock"')

meta = {
    "run_id": run_id,
    "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    "report_type": report_type,
    "models": {
        "fast": fast_llm,
        "smart": smart_llm,
        "strategic": strategic_llm,
    },
    "run_params": {
        "mode": first_match(r"^mode=(.*)$"),
        "report_source": first_match(r"^report_source=(.*)$"),
        "input_mode": first_match(r"^input_mode=(.*)$"),
        "input_file": first_match(r"^input_file=(.*)$"),
        "report_type": first_match(r"^report_type=(.*)$", report_type),
        "web_timeout_seconds": first_match(r"^web_timeout_seconds=(.*)$"),
        "soft_limit_enabled": first_match(r"^soft_limit_enabled=(.*)$"),
        "soft_limit_tavily_calls": first_match(r"^soft_limit_tavily_calls=(.*)$"),
        "soft_limit_bedrock_total_tokens": first_match(r"^soft_limit_bedrock_total_tokens=(.*)$"),
        "soft_limit_elapsed_seconds": first_match(r"^soft_limit_elapsed_seconds=(.*)$"),
        "soft_limit_max_subqueries": first_match(r"^soft_limit_max_subqueries=(.*)$"),
    },
    "counts": {
        "planning_web_passes": count(r"🌐 Browsing the web to learn more about the task:"),
        "running_subqueries": count(r"🔍 Running research for '"),
        "source_urls_added": count(r"✅ Added source url to research:"),
        "throttling_errors": count(r"ThrottlingException"),
    },
    "phases": phase_durations,
    "bedrock": bedrock,
    "bedrock_by_stage": bedrock_by_stage,
    "bedrock_by_step": bedrock_by_step,
    "bedrock_by_model": bedrock_by_model,
    "tavily": tavily,
    "soft_limit": soft_limit,
    "stage_calls": {
        "prefilter_calls": pre_filter_usage_calls,
        "translation_calls": translation_calls,
    },
}
print(json.dumps(meta, ensure_ascii=False))
PY
)"

TELEMETRY_FILE="$LOGS_DIR/${RUN_ID}-telemetry.json"
printf "%s\n" "$telemetry_json" > "$TELEMETRY_FILE"

telemetry_md="$(python3 - "$TELEMETRY_FILE" <<'PY'
import json, sys
from pathlib import Path
t = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
phases = t.get("phases", {})
bed = t.get("bedrock", {})
tav = t.get("tavily", {})
params = t.get("run_params", {})
cnt = t.get("counts", {})
soft = t.get("soft_limit", {})
stage_calls = t.get("stage_calls", {})
stage_bedrock = t.get("bedrock_by_stage", {})
step_bedrock = t.get("bedrock_by_step", {})
model_bedrock = t.get("bedrock_by_model", {})

def d(name):
    return phases.get(name, {}).get("duration_s", 0)

def usd(v):
    return f"${float(v or 0.0):.6f}"

def fmt_int(v):
    return f"{int(v or 0):,}"

def row(name, stats):
    return (
        f"| {name} | {fmt_int(stats.get('calls',0))} | {usd(stats.get('estimated_cost_usd',0.0))} "
        f"| {fmt_int(stats.get('input_tokens',0))} | {fmt_int(stats.get('output_tokens',0))} "
        f"| {fmt_int(stats.get('cache_read_input_tokens',0))} | {fmt_int(stats.get('cache_write_input_tokens',0))} |"
    )

lines = []
lines.append("## Телеметрия запуска")
lines.append("")
lines.append("### Сводка")
lines.append("")
lines.append(f"- Run ID: `{t.get('run_id','')}`")
lines.append(f"- Время генерации (UTC): `{t.get('generated_at_utc','')}`")
lines.append(f"- Тип отчета: `{t.get('report_type','')}`")
lines.append(f"- Общая стоимость Bedrock: `{usd(bed.get('estimated_cost_usd',0.0))}`")
lines.append(
    f"- Bedrock всего: calls `{fmt_int(bed.get('calls',0))}`, input `{fmt_int(bed.get('input_tokens',0))}`, "
    f"output `{fmt_int(bed.get('output_tokens',0))}`, cache_read `{fmt_int(bed.get('cache_read_input_tokens',0))}`, "
    f"cache_write `{fmt_int(bed.get('cache_write_input_tokens',0))}`"
)
lines.append(
    f"- Tavily: calls `{fmt_int(tav.get('calls_dedup', tav.get('calls',0)))}`, failed `{fmt_int(tav.get('failed_calls',0))}`, "
    f"estimated_credits `{float(tav.get('estimated_credits',0.0)):.2f}`"
)
lines.append(
    f"- Длительность фаз (сек): prefilter `{d('prefilter')}`, research_web `{d('research_web')}`, translation_ru `{d('translation_ru')}`"
)
lines.append(
    f"- Активность: planning_web_passes `{fmt_int(cnt.get('planning_web_passes',0))}`, running_subqueries `{fmt_int(cnt.get('running_subqueries',0))}`, "
    f"source_urls_added `{fmt_int(cnt.get('source_urls_added',0))}`, throttling_errors `{fmt_int(cnt.get('throttling_errors',0))}`"
)
lines.append(
    f"- Лимиты: soft_limit_enabled `{params.get('soft_limit_enabled','')}`, tavily_calls `{params.get('soft_limit_tavily_calls','')}`, "
    f"bedrock_total_tokens `{params.get('soft_limit_bedrock_total_tokens','')}`, elapsed_seconds `{params.get('soft_limit_elapsed_seconds','')}`, "
    f"max_subqueries `{params.get('soft_limit_max_subqueries','')}`"
)
lines.append(
    f"- Soft limit triggered: `{str(soft.get('triggered', False)).lower()}`" +
    (f", reason `{soft.get('reason','')}`" if soft.get("reason") else "")
)
lines.append("")
lines.append("### Bedrock по этапам")
lines.append("")
lines.append("| Этап | Calls | Cost USD | Input tokens | Output tokens | Cache read | Cache write |")
lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
for stage_name in ("prefilter", "research", "translation"):
    lines.append(row(stage_name, stage_bedrock.get(stage_name, {})))
lines.append("")
nonzero_steps = [
    (name, stats) for name, stats in step_bedrock.items()
    if int(stats.get("calls", 0)) > 0 or float(stats.get("estimated_cost_usd", 0.0)) > 0
]
if nonzero_steps:
    lines.append("### Bedrock по шагам")
    lines.append("")
    lines.append("| Шаг | Calls | Cost USD | Input tokens | Output tokens | Cache read | Cache write |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for name, stats in sorted(nonzero_steps, key=lambda item: (-float(item[1].get("estimated_cost_usd", 0.0)), item[0])):
        lines.append(row(name, stats))
    lines.append("")
nonzero_models = [
    (name, stats) for name, stats in model_bedrock.items()
    if int(stats.get("calls", 0)) > 0 or float(stats.get("estimated_cost_usd", 0.0)) > 0
]
if nonzero_models:
    lines.append("### Bedrock по моделям")
    lines.append("")
    lines.append("| Модель | Calls | Cost USD | Input tokens | Output tokens | Cache read | Cache write |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for name, stats in sorted(nonzero_models, key=lambda item: (-float(item[1].get("estimated_cost_usd", 0.0)), item[0])):
        lines.append(row(name, stats))
    lines.append("")
lines.append("### Технические параметры")
lines.append("")
lines.append(f"- Models: FAST `{t['models']['fast']}`, SMART `{t['models']['smart']}`, STRATEGIC `{t['models']['strategic']}`")
lines.append(
    f"- Run params: report_source `{params.get('report_source','')}`, report_type `{params.get('report_type','')}`, "
    f"input_mode `{params.get('input_mode','')}`, web_timeout_seconds `{params.get('web_timeout_seconds','')}`"
)
lines.append(
    f"- Stage call counters: prefilter `{stage_calls.get('prefilter_calls',0)}`, translation `{stage_calls.get('translation_calls',0)}`"
)
print("\n".join(lines))
PY
)"

printf "\n\n%s\n" "$telemetry_md" >> "$DEST_REPORT"
echo "Saved telemetry: $TELEMETRY_FILE"

echo "Saved log: $RUN_LOG"
echo "Saved report: $DEST_REPORT"
