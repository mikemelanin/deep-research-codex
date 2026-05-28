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

print_usage() {
  echo "Usage: ./research.sh [--ru|--en] [--file /path/input.txt|.md] \"/path/notes.md\" | \"topic or raw dump\""
}

if [[ $# -lt 1 ]]; then
  print_usage
  exit 1
fi

TRANSLATE_TO_RU=1
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
if [[ -z "$INPUT_FILE" && "$#" -eq 1 && -f "$1" && "$1" == *.md ]]; then
  INPUT_FILE="$1"
  QUERY_RAW=""
fi
if [[ -z "$INPUT_FILE" && -z "$QUERY_RAW" ]]; then
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

REPORT_TYPE="${REPORT_TYPE:-research_report}"
DEEP_RESEARCH_BREADTH="${DEEP_RESEARCH_BREADTH:-4}"
DEEP_RESEARCH_DEPTH="${DEEP_RESEARCH_DEPTH:-2}"
DEEP_RESEARCH_CONCURRENCY="${DEEP_RESEARCH_CONCURRENCY:-4}"
WEB_TIMEOUT_SECONDS="${WEB_TIMEOUT_SECONDS:-1200}"
SOFT_LIMIT_ENABLED="${SOFT_LIMIT_ENABLED:-1}"
SOFT_LIMIT_TAVILY_CALLS="${SOFT_LIMIT_TAVILY_CALLS:-25}"
SOFT_LIMIT_BEDROCK_TOTAL_TOKENS="${SOFT_LIMIT_BEDROCK_TOTAL_TOKENS:-300000}"
SOFT_LIMIT_ELAPSED_SECONDS="${SOFT_LIMIT_ELAPSED_SECONDS:-600}"
SOFT_LIMIT_MAX_SUBQUERIES="${SOFT_LIMIT_MAX_SUBQUERIES:-12}"
RUN_STARTED_AT_EPOCH="$(date +%s)"
export REPORT_TYPE DEEP_RESEARCH_BREADTH DEEP_RESEARCH_DEPTH DEEP_RESEARCH_CONCURRENCY
export SOFT_LIMIT_ENABLED SOFT_LIMIT_TAVILY_CALLS SOFT_LIMIT_BEDROCK_TOTAL_TOKENS SOFT_LIMIT_ELAPSED_SECONDS SOFT_LIMIT_MAX_SUBQUERIES RUN_STARTED_AT_EPOCH

mkdir -p "$REPORTS_DIR" "$LOGS_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOGS_DIR/${RUN_ID}-research.log"

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

RAW_INPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-raw-input.${RUN_ID}.XXXXXX")"
PREFILTER_QUERY_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-query.${RUN_ID}.XXXXXX")"
PREFILTER_BRIEF_FILE="$LOGS_DIR/${RUN_ID}-prefilter-brief.md"
RAW_OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/gpt-research-raw.${RUN_ID}.XXXXXX")"
trap '[[ -f "$RAW_INPUT_FILE" ]] && rm -f "$RAW_INPUT_FILE"; [[ -f "$PREFILTER_QUERY_FILE" ]] && rm -f "$PREFILTER_QUERY_FILE"; [[ -f "$RAW_OUTPUT_FILE" ]] && rm -f "$RAW_OUTPUT_FILE"' EXIT

if [[ -n "$INPUT_FILE" ]]; then
  cat "$INPUT_FILE" > "$RAW_INPUT_FILE"
else
  printf '%s\n' "$QUERY_RAW" > "$RAW_INPUT_FILE"
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

phase_start "prefilter"
log_ts "prefilter_start input=$( [[ -n "$INPUT_FILE" ]] && echo file_as_query || echo inline_text )"
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

{
  echo "run_id=$RUN_ID"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mode=web_only"
  echo "report_source=web"
  echo "input_mode=$( [[ -n "$INPUT_FILE" ]] && echo file_as_query || echo inline_text )"
  echo "input_file=${INPUT_FILE:-}"
  echo "prefilter_brief=$PREFILTER_BRIEF_FILE"
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
bedrock = {
    "calls": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_input_tokens": 0,
    "cache_write_input_tokens": 0,
    "estimated_cost_usd": 0.0,
}
bedrock_by_stage = {
    "prefilter": {
        "calls": 0, "input_tokens": 0, "output_tokens": 0,
        "cache_read_input_tokens": 0, "cache_write_input_tokens": 0, "estimated_cost_usd": 0.0,
    },
    "research": {
        "calls": 0, "input_tokens": 0, "output_tokens": 0,
        "cache_read_input_tokens": 0, "cache_write_input_tokens": 0, "estimated_cost_usd": 0.0,
    },
    "translation": {
        "calls": 0, "input_tokens": 0, "output_tokens": 0,
        "cache_read_input_tokens": 0, "cache_write_input_tokens": 0, "estimated_cost_usd": 0.0,
    },
}
tavily = {
    "calls_dedup": 0,
    "raw_events": 0,
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

for raw in tel_lines:
    payload = raw[len("TELEMETRY_JSON "):]
    try:
        item = json.loads(payload)
    except Exception:
        continue
    typ = item.get("type")
    if typ == "bedrock_usage":
        usage = item.get("usage", {}) or {}
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
        bedrock["calls"] += 1
        bedrock["input_tokens"] += inp
        bedrock["output_tokens"] += out
        bedrock["cache_read_input_tokens"] += cr
        bedrock["cache_write_input_tokens"] += cw
        event_cost = float(item.get("estimated_cost_usd", 0.0) or 0.0)
        if event_cost <= 0:
            event_cost = estimate_bedrock_usage_cost(item.get("model", ""), usage)
        bedrock["estimated_cost_usd"] += event_cost
    elif typ in ("prefilter_bedrock", "translation_bedrock"):
        usage = item.get("usage", {}) or {}
        model_name = item.get("model", "")
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
        bedrock["calls"] += 1
        bedrock["input_tokens"] += inp
        bedrock["output_tokens"] += out
        bedrock["cache_read_input_tokens"] += cr
        bedrock["cache_write_input_tokens"] += cw
        c = estimate_bedrock_usage_cost(model_name, usage)
        bedrock["estimated_cost_usd"] += c
        stage_key = "prefilter" if typ == "prefilter_bedrock" else "translation"
        stage = bedrock_by_stage[stage_key]
        stage["calls"] += 1
        stage["input_tokens"] += int(usage.get("inputTokens", 0) or 0)
        stage["output_tokens"] += int(usage.get("outputTokens", 0) or 0)
        stage["cache_read_input_tokens"] += int(usage.get("cacheReadInputTokens", 0) or 0)
        stage["cache_write_input_tokens"] += int(usage.get("cacheWriteInputTokens", 0) or 0)
        stage["estimated_cost_usd"] += c
    elif typ == "bedrock_usage_step":
        step_name = str(item.get("step", "research"))
        if step_name in ("agent_selection", "research", "report_writing", "deep_research"):
            usage = item.get("usage", {}) or {}
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
            stage = bedrock_by_stage["research"]
            stage["calls"] += 1
            stage["input_tokens"] += inp
            stage["output_tokens"] += out
            stage["cache_read_input_tokens"] += cr
            stage["cache_write_input_tokens"] += cw
            stage["estimated_cost_usd"] += float(item.get("estimated_cost_usd", 0.0) or 0.0)
    elif typ == "tavily_usage":
        tavily["raw_events"] += 1
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

telemetry_md="$(python3 - "$telemetry_json" <<'PY'
import json, sys
t = json.loads(sys.argv[1])
phases = t.get("phases", {})
bed = t.get("bedrock", {})
tav = t.get("tavily", {})
params = t.get("run_params", {})
cnt = t.get("counts", {})
soft = t.get("soft_limit", {})
stage_calls = t.get("stage_calls", {})
stage_bedrock = t.get("bedrock_by_stage", {})

def d(name):
    return phases.get(name, {}).get("duration_s", 0)

lines = []
lines.append("## Run telemetry")
lines.append("")
lines.append(f"- Run ID: `{t.get('run_id','')}`")
lines.append(f"- Generated at (UTC): `{t.get('generated_at_utc','')}`")
lines.append(f"- Report type: `{t.get('report_type','')}`")
lines.append(f"- Models: FAST `{t['models']['fast']}`, SMART `{t['models']['smart']}`, STRATEGIC `{t['models']['strategic']}`")
lines.append(f"- Duration by phase (s): prefilter `{d('prefilter')}`, research_web `{d('research_web')}`, translation_ru `{d('translation_ru')}`")
lines.append(
    f"- Run params: report_source `{params.get('report_source','')}`, report_type `{params.get('report_type','')}`, input_mode `{params.get('input_mode','')}`, web_timeout_seconds `{params.get('web_timeout_seconds','')}`, soft_limit_enabled `{params.get('soft_limit_enabled','')}`, soft_limit_tavily_calls `{params.get('soft_limit_tavily_calls','')}`, soft_limit_bedrock_total_tokens `{params.get('soft_limit_bedrock_total_tokens','')}`, soft_limit_elapsed_seconds `{params.get('soft_limit_elapsed_seconds','')}`, soft_limit_max_subqueries `{params.get('soft_limit_max_subqueries','')}`"
)
lines.append(f"- Bedrock calls/tokens: calls `{bed.get('calls',0)}`, input `{bed.get('input_tokens',0)}`, output `{bed.get('output_tokens',0)}`, cache_read `{bed.get('cache_read_input_tokens',0)}`, cache_write `{bed.get('cache_write_input_tokens',0)}`")
lines.append(f"- Bedrock estimated cost (USD): `${bed.get('estimated_cost_usd',0.0):.6f}`")
lines.append(f"- Tavily usage: calls_dedup `{tav.get('calls_dedup', tav.get('calls',0))}`, failed `{tav.get('failed_calls',0)}`, estimated_credits `{tav.get('estimated_credits',0.0):.2f}`, raw_events `{tav.get('raw_events',0)}`")
lines.append(f"- Research activity: planning_web_passes `{cnt.get('planning_web_passes',0)}`, running_subqueries `{cnt.get('running_subqueries',0)}`, source_urls_added `{cnt.get('source_urls_added',0)}`, throttling_errors `{cnt.get('throttling_errors',0)}`")
for stage_name in ("prefilter", "research", "translation"):
    s = stage_bedrock.get(stage_name, {})
    lines.append(
        f"- Bedrock {stage_name}: calls `{s.get('calls',0)}`, input `{s.get('input_tokens',0)}`, output `{s.get('output_tokens',0)}`, cache_read `{s.get('cache_read_input_tokens',0)}`, cache_write `{s.get('cache_write_input_tokens',0)}`, est_cost `${s.get('estimated_cost_usd',0.0):.6f}`"
    )
lines.append(f"- Stage Bedrock call counters: prefilter `{stage_calls.get('prefilter_calls',0)}`, translation `{stage_calls.get('translation_calls',0)}`")
lines.append(f"- Soft limit: triggered `{str(soft.get('triggered', False)).lower()}`" + (f", reason `{soft.get('reason','')}`" if soft.get("reason") else ""))
print("\n".join(lines))
PY
)"

printf "\n\n%s\n" "$telemetry_md" >> "$DEST_REPORT"
printf "%s\n" "$telemetry_json" > "$LOGS_DIR/${RUN_ID}-telemetry.json"
echo "Saved telemetry: $LOGS_DIR/${RUN_ID}-telemetry.json"

echo "Saved log: $RUN_LOG"
echo "Saved report: $DEST_REPORT"
