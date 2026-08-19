#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected exactly one {description}; found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: refine_candidate.py <containerd-source-root>")

    source_root = Path(sys.argv[1])
    monitor_path = source_root / "plugins/restart/monitor.go"
    text = monitor_path.read_text(encoding="utf-8")

    text = replace_once(
        text,
        "\tticker := time.NewTicker(interval)\n\tdefer ticker.Stop()\n\n\tfor {\n",
        "\tfor {\n",
        "ticker setup",
    )
    text = replace_once(
        text,
        "\t\tselect {\n\t\tcase <-ctx.Done():\n\t\t\treturn\n\t\tcase <-ticker.C:\n\t\t}\n",
        "\t\t// Preserve the original behavior of waiting a full interval after\n"
        "\t\t// each reconciliation while still allowing prompt cancellation.\n"
        "\t\ttimer := time.NewTimer(interval)\n"
        "\t\tselect {\n"
        "\t\tcase <-ctx.Done():\n"
        "\t\t\ttimer.Stop()\n"
        "\t\t\treturn\n"
        "\t\tcase <-timer.C:\n"
        "\t\t}\n",
        "ticker wait",
    )

    monitor_path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
