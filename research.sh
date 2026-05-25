#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/gpt-researcher"
REPORTS_DIR="$HOME/Downloads"
ENV_FILE="$ROOT_DIR/.env"

if [[ $# -lt 1 ]]; then
  echo "Usage: ./research.sh [--ru|--en] \"topic\""
  exit 1
fi

TRANSLATE_TO_RU=1
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

if [[ $# -lt 1 ]]; then
  echo "Usage: ./research.sh [--ru|--en] \"topic\""
  exit 1
fi

QUERY="$*"

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

RAW_OUTPUT="$(cd "$APP_DIR" && python cli.py "$QUERY" --report_type research_report --report_source web --no-pdf --no-docx 2>&1)" || {
  echo "$RAW_OUTPUT"
  echo "Error: GPT Researcher execution failed"
  exit 1
}

echo "$RAW_OUTPUT"

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

if [[ "$TRANSLATE_TO_RU" -eq 1 ]]; then
  DEST_REPORT="${BASE_REPORT_PATH}-ru.md"
  export SRC_REPORT DEST_REPORT
  python - <<'PY'
import os
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

prompt = (
    "Translate the following markdown report to Russian. "
    "Keep markdown structure, headings, links, citations, and formatting unchanged. "
    "Preserve technical terms, product names, framework names, code identifiers, and model names in original form unless natural Russian spelling is standard. "
    "Do not add comments or extra sections.\n\n"
    + content
)

try:
    client = boto3.client("bedrock-runtime", region_name=region)
    resp = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 4000, "temperature": 0},
    )
    ru_text = resp["output"]["message"]["content"][0]["text"]
    dst.write_text(ru_text, encoding="utf-8")
    print(f"Saved report: {dst}")
except (ClientError, BotoCoreError, Exception) as e:
    print(f"Warning: RU translation failed: {e}")
    dst.write_text(content, encoding="utf-8")
    print(f"Saved report: {dst}")
PY
else
  DEST_REPORT="${BASE_REPORT_PATH}.md"
  cp "$SRC_REPORT" "$DEST_REPORT"
  echo "Saved report: $DEST_REPORT"
fi
