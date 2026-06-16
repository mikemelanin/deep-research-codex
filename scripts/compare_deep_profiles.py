#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
LOGS_DIR = ROOT_DIR / "logs"

PROFILES = [
    {
        "name": "baseline_2-2-2",
        "label": "2/2/2",
        "breadth": 2,
        "depth": 2,
        "concurrency": 2,
        "soft_limit_max_subqueries": 6,
        "soft_limit_tavily_calls": 10,
        "soft_limit_bedrock_total_tokens": 120000,
        "soft_limit_elapsed_seconds": 420,
    },
    {
        "name": "candidate_4-2-4",
        "label": "4/2/4",
        "breadth": 4,
        "depth": 2,
        "concurrency": 4,
        "soft_limit_max_subqueries": 8,
        "soft_limit_tavily_calls": 14,
        "soft_limit_bedrock_total_tokens": 160000,
        "soft_limit_elapsed_seconds": 540,
    },
    {
        "name": "depth_test_2-4-4",
        "label": "2/4/4",
        "breadth": 2,
        "depth": 4,
        "concurrency": 4,
        "soft_limit_max_subqueries": 8,
        "soft_limit_tavily_calls": 14,
        "soft_limit_bedrock_total_tokens": 160000,
        "soft_limit_elapsed_seconds": 540,
    },
]


def slugify(value: str, limit: int = 48) -> str:
    slug = re.sub(r"[^\w]+", "-", value.strip().lower(), flags=re.UNICODE).strip("-_")
    return (slug[:limit] or "topic")


def run_streaming(cmd: list[str], env: dict[str, str] | None = None) -> tuple[int, str]:
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env or os.environ.copy(),
    )
    assert proc.stdout is not None
    lines: list[str] = []
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        lines.append(line)
    code = proc.wait()
    return code, "".join(lines)


def find_output_value(output: str, key: str) -> str:
    match = re.search(rf"^{re.escape(key)}:\s*(.+)$", output, re.M)
    return match.group(1).strip() if match else ""


def parse_source_report(log_path: Path) -> str:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^source_report=(.+)$", text, re.M)
    return match.group(1).strip() if match else ""


def summarize_report(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    words = len(re.findall(r"\w+", text, re.UNICODE))
    headings = len(re.findall(r"^#+\s", text, re.M))
    urls = len(re.findall(r"https?://", text))
    return {
        "chars": len(text),
        "words": words,
        "headings": headings,
        "urls": urls,
    }


def copy_artifact(src: str, dst: Path) -> str:
    src_path = Path(src).expanduser().resolve()
    shutil.copy2(src_path, dst)
    return str(dst)


def build_result(profile: dict, exit_code: int, telemetry_path: Path, log_path: Path, report_path: Path) -> dict:
    telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
    report_stats = summarize_report(report_path)
    phases = telemetry.get("phases", {})
    research_phase = phases.get("research_web", {})
    translation_phase = phases.get("translation_ru", {})
    bedrock = telemetry.get("bedrock", {})
    bedrock_by_stage = telemetry.get("bedrock_by_stage", {})
    tavily = telemetry.get("tavily", {})
    counts = telemetry.get("counts", {})
    soft = telemetry.get("soft_limit", {})
    return {
        "profile": profile,
        "exit_code": exit_code,
        "success": exit_code == 0 and research_phase.get("reason") == "success",
        "research_reason": research_phase.get("reason", ""),
        "research_duration_s": int(research_phase.get("duration_s", 0) or 0),
        "translation_reason": translation_phase.get("reason", ""),
        "translation_duration_s": int(translation_phase.get("duration_s", 0) or 0),
        "running_subqueries": int(counts.get("running_subqueries", 0) or 0),
        "source_urls_added": int(counts.get("source_urls_added", 0) or 0),
        "planning_web_passes": int(counts.get("planning_web_passes", 0) or 0),
        "throttling_errors": int(counts.get("throttling_errors", 0) or 0),
        "soft_limit_triggered": bool(soft.get("triggered", False)),
        "soft_limit_reason": soft.get("reason", ""),
        "bedrock_total_cost_usd": float(bedrock.get("estimated_cost_usd", 0.0) or 0.0),
        "bedrock_research_cost_usd": float(bedrock_by_stage.get("research", {}).get("estimated_cost_usd", 0.0) or 0.0),
        "bedrock_translation_cost_usd": float(bedrock_by_stage.get("translation", {}).get("estimated_cost_usd", 0.0) or 0.0),
        "bedrock_calls": int(bedrock.get("calls", 0) or 0),
        "tavily_calls": int(tavily.get("calls", tavily.get("calls_dedup", 0)) or 0),
        "tavily_failed_calls": int(tavily.get("failed_calls", 0) or 0),
        "tavily_estimated_credits": float(tavily.get("estimated_credits", 0.0) or 0.0),
        "report_stats": report_stats,
        "artifact_paths": {
            "telemetry": str(telemetry_path),
            "log": str(log_path),
            "report": str(report_path),
        },
    }


def render_summary_markdown(query: str, prefilter_artifact: str, results: list[dict]) -> str:
    lines = []
    lines.append("# Deep profile comparison")
    lines.append("")
    lines.append(f"- Query: `{query}`")
    lines.append(f"- Prefilter artifact: `{prefilter_artifact}`")
    lines.append(f"- Generated at (UTC): `{datetime.now(timezone.utc).isoformat()}`")
    lines.append("")
    lines.append("| Profile | OK | Research s | Subqueries | Sources | Tavily calls | Tavily credits | Research cost | Translation cost | Total cost | Soft limit | Report words | URLs |")
    lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |")
    for result in results:
        stats = result["report_stats"]
        lines.append(
            f"| {result['profile']['label']} | {'yes' if result['success'] else 'no'} | "
            f"{result['research_duration_s']} | {result['running_subqueries']} | {result['source_urls_added']} | "
            f"{result['tavily_calls']} | {result['tavily_estimated_credits']:.2f} | "
            f"${result['bedrock_research_cost_usd']:.6f} | ${result['bedrock_translation_cost_usd']:.6f} | "
            f"${result['bedrock_total_cost_usd']:.6f} | "
            f"{'yes' if result['soft_limit_triggered'] else 'no'}"
            + (f" ({result['soft_limit_reason']})" if result["soft_limit_reason"] else "")
            + f" | {stats['words']} | {stats['urls']} |"
        )
    lines.append("")
    lines.append("## Notes")
    lines.append("")
    for result in results:
        lines.append(f"### {result['profile']['label']}")
        lines.append("")
        lines.append(
            f"- Status: `{'success' if result['success'] else 'failed'}`; "
            f"exit_code `{result['exit_code']}`, research_reason `{result['research_reason']}`"
        )
        lines.append(
            f"- Costs: research `${result['bedrock_research_cost_usd']:.6f}`, "
            f"translation `${result['bedrock_translation_cost_usd']:.6f}`, total `${result['bedrock_total_cost_usd']:.6f}`"
        )
        lines.append(
            f"- Activity: subqueries `{result['running_subqueries']}`, sources `{result['source_urls_added']}`, "
            f"planning_web_passes `{result['planning_web_passes']}`, throttling_errors `{result['throttling_errors']}`"
        )
        lines.append(
            f"- Artifacts: report `{result['artifact_paths']['report']}`, telemetry `{result['artifact_paths']['telemetry']}`, log `{result['artifact_paths']['log']}`"
        )
        lines.append("")
    return "\n".join(lines).strip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run comparable deep-research profiles against one prefilter artifact.")
    parser.add_argument("query", nargs="?", help="Topic or raw query text for prefilter.")
    parser.add_argument("--from-prefilter", dest="from_prefilter", help="Use an existing prefilter artifact instead of generating one.")
    parser.add_argument("--output-dir", dest="output_dir", help="Where to save comparison artifacts.")
    args = parser.parse_args()

    if not args.query and not args.from_prefilter:
        parser.error("Provide either a query or --from-prefilter")

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    topic_slug = slugify(args.query or Path(args.from_prefilter).stem)
    comparison_dir = Path(args.output_dir) if args.output_dir else LOGS_DIR / f"{timestamp}-deep-compare-{topic_slug}"
    comparison_dir.mkdir(parents=True, exist_ok=True)

    if args.from_prefilter:
        prefilter_artifact = str(Path(args.from_prefilter).expanduser().resolve())
        query_text = ""
    else:
        cmd = ["./research.sh", "--yes", "--prefilter-only", "--no-translate", args.query]
        code, output = run_streaming(cmd)
        if code != 0:
            print(f"Prefilter run failed with exit code {code}", file=sys.stderr)
            return code
        prefilter_artifact = find_output_value(output, "PREFILTER_ARTIFACT")
        query_text = find_output_value(output, "PREFILTER_QUERY")
        if not prefilter_artifact:
            print("Could not parse PREFILTER_ARTIFACT from prefilter output", file=sys.stderr)
            return 1

    artifact_copy = comparison_dir / "prefilter.json"
    copy_artifact(prefilter_artifact, artifact_copy)

    if not query_text:
        query_text = json.loads(Path(prefilter_artifact).read_text(encoding="utf-8")).get("normalized_query", "")

    results: list[dict] = []
    for profile in PROFILES:
        print(f"\n===== Running profile {profile['label']} =====\n", flush=True)
        env = os.environ.copy()
        env.update(
            {
                "REPORT_TYPE": "deep",
                "DEEP_RESEARCH_BREADTH": str(profile["breadth"]),
                "DEEP_RESEARCH_DEPTH": str(profile["depth"]),
                "DEEP_RESEARCH_CONCURRENCY": str(profile["concurrency"]),
                "SOFT_LIMIT_ENABLED": "1",
                "SOFT_LIMIT_MAX_SUBQUERIES": str(profile["soft_limit_max_subqueries"]),
                "SOFT_LIMIT_TAVILY_CALLS": str(profile["soft_limit_tavily_calls"]),
                "SOFT_LIMIT_BEDROCK_TOTAL_TOKENS": str(profile["soft_limit_bedrock_total_tokens"]),
                "SOFT_LIMIT_ELAPSED_SECONDS": str(profile["soft_limit_elapsed_seconds"]),
            }
        )
        cmd = ["./research.sh", "--yes", "--deep", "--no-translate", "--from-prefilter", str(artifact_copy)]
        exit_code, output = run_streaming(cmd, env=env)

        telemetry_src = find_output_value(output, "Saved telemetry")
        log_src = find_output_value(output, "Saved log")
        report_src = find_output_value(output, "Saved report")
        if not telemetry_src or not log_src or not report_src:
            print(f"Could not parse artifacts for profile {profile['label']}", file=sys.stderr)
            return 1

        log_path = Path(log_src).expanduser().resolve()
        source_report_src = parse_source_report(log_path) or report_src

        telemetry_copy = comparison_dir / f"{profile['name']}-telemetry.json"
        log_copy = comparison_dir / f"{profile['name']}-research.log"
        report_copy = comparison_dir / f"{profile['name']}-report.md"

        copy_artifact(telemetry_src, telemetry_copy)
        copy_artifact(log_src, log_copy)
        copy_artifact(source_report_src, report_copy)

        results.append(build_result(profile, exit_code, telemetry_copy, log_copy, report_copy))

    summary = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "query": query_text,
        "prefilter_artifact": str(artifact_copy),
        "results": results,
    }
    summary_json_path = comparison_dir / "comparison-summary.json"
    summary_json_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    summary_md_path = comparison_dir / "comparison-summary.md"
    summary_md_path.write_text(render_summary_markdown(query_text, str(artifact_copy), results), encoding="utf-8")

    print(f"\nComparison summary JSON: {summary_json_path}")
    print(f"Comparison summary MD: {summary_md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
