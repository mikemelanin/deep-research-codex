#!/usr/bin/env python3
import os
import selectors
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 5:
        print("Usage: run_research_cli.py <app_dir> <query> <timeout_sec> <raw_output_file>", file=sys.stderr)
        return 2

    app_dir, query, timeout_sec, raw_file = sys.argv[1:]
    timeout_sec_int = int(timeout_sec)

    cmd = [
        sys.executable,
        "cli.py",
        query,
        "--report_type",
        os.environ.get("REPORT_TYPE", "research_report"),
        "--report_source",
        "web",
        "--no-pdf",
        "--no-docx",
    ]

    try:
        proc = subprocess.Popen(
            cmd,
            cwd=app_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )
        started = time.monotonic()
        output_chunks: list[str] = []
        selector = selectors.DefaultSelector()
        assert proc.stdout is not None
        selector.register(proc.stdout, selectors.EVENT_READ)

        with Path(raw_file).open("w", encoding="utf-8") as sink:
            while True:
                elapsed = time.monotonic() - started
                if elapsed >= timeout_sec_int:
                    proc.kill()
                    proc.wait()
                    remainder = proc.stdout.read() or ""
                    if remainder:
                        output_chunks.append(remainder)
                        sink.write(remainder)
                        sink.flush()
                        print(remainder, end="")
                    print(f"\nError: CLI timed out after {timeout_sec_int}s")
                    return 124

                events = selector.select(timeout=1.0)
                if events:
                    for key, _ in events:
                        line = key.fileobj.readline()
                        if not line:
                            continue
                        output_chunks.append(line)
                        sink.write(line)
                        sink.flush()
                        print(line, end="")

                if proc.poll() is not None:
                    remainder = proc.stdout.read() or ""
                    if remainder:
                        output_chunks.append(remainder)
                        sink.write(remainder)
                        sink.flush()
                        print(remainder, end="")
                    break

        return proc.returncode
    except KeyboardInterrupt:
        print("\nInterrupted by user.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
