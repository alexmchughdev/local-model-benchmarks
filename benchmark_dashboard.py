#!/usr/bin/env python3
"""
Generate an offline HTML dashboard and standalone SVG figures from llama-bench JSON.

The script intentionally uses only Python's standard library so it can run on a
benchmark host, inside a container, or on a desktop machine without installing
plotting packages.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import html
import json
import math
import os
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean
from typing import Any, Iterable


PALETTE = [
    "#276A73",
    "#B85545",
    "#607D3B",
    "#8A6E2F",
    "#4F6EA8",
    "#8A4F7D",
    "#58707A",
    "#C06C2D",
    "#6A5E9A",
    "#3B7D62",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert llama-bench JSON output into an offline HTML dashboard with SVG figures."
    )
    parser.add_argument(
        "input_json",
        help="Path to llama-bench-results.json or llama-bench-results.jsonl",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        help="Output directory. Defaults to <input directory>/dashboard.",
    )
    parser.add_argument(
        "--title",
        default="Local Model Benchmark Dashboard",
        help="Dashboard title.",
    )
    parser.add_argument(
        "--max-bars",
        type=int,
        default=40,
        help="Maximum bars shown in each horizontal bar figure.",
    )
    parser.add_argument(
        "--thermal-limit-c",
        type=float,
        default=85.0,
        help="CPU temperature limit used by the sustained-use score. Default: 85 C.",
    )
    parser.add_argument(
        "--primary-type",
        default="auto",
        help="Benchmark type to use for sustained-use ranking. Default: auto, preferring tg when present.",
    )
    return parser.parse_args()


def load_records(path: Path) -> list[dict[str, Any]]:
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return []

    try:
        data = json.loads(text)
        if isinstance(data, list):
            return [row for row in data if isinstance(row, dict)]
        if isinstance(data, dict):
            return [data]
    except json.JSONDecodeError:
        pass

    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Invalid JSON on line {line_number}: {exc}") from exc
        if isinstance(row, dict):
            records.append(row)
    return records


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "-", value).strip("-").lower()
    return slug or "figure"


def esc(value: Any) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def short_model_name(value: str) -> str:
    name = os.path.basename(value or "unknown-model")
    for suffix in (".gguf", ".bin"):
        if name.lower().endswith(suffix):
            name = name[: -len(suffix)]
    return name


def number(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        if math.isnan(value) or math.isinf(value):
            return None
        return float(value)
    try:
        parsed = float(str(value))
    except (TypeError, ValueError):
        return None
    if math.isnan(parsed) or math.isinf(parsed):
        return None
    return parsed


def integerish(value: Any) -> int | None:
    parsed = number(value)
    if parsed is None:
        return None
    return int(parsed)


def nested(record: dict[str, Any], key: str, child: str) -> Any:
    value = record.get(key)
    if isinstance(value, dict):
        return value.get(child)
    return None


def fmt(value: Any, digits: int = 2) -> str:
    parsed = number(value)
    if parsed is None:
        return ""
    if abs(parsed - round(parsed)) < 0.005:
        return str(int(round(parsed)))
    return f"{parsed:.{digits}f}".rstrip("0").rstrip(".")


def mean_or_none(values: Iterable[float | None]) -> float | None:
    cleaned = [value for value in values if value is not None]
    if not cleaned:
        return None
    return mean(cleaned)


def max_or_none(values: Iterable[float | None]) -> float | None:
    cleaned = [value for value in values if value is not None]
    if not cleaned:
        return None
    return max(cleaned)


def normalise_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalised: list[dict[str, Any]] = []
    for record in records:
        test_metadata = record.get("test_metadata")
        if not isinstance(test_metadata, dict):
            test_metadata = {}
        hardware_metadata = record.get("hardware_metadata")
        if not isinstance(hardware_metadata, dict):
            hardware_metadata = {}
        hardware_system = hardware_metadata.get("system")
        if not isinstance(hardware_system, dict):
            hardware_system = {}
        hardware_cpu = hardware_metadata.get("cpu")
        if not isinstance(hardware_cpu, dict):
            hardware_cpu = {}
        hardware_memory = hardware_metadata.get("memory")
        if not isinstance(hardware_memory, dict):
            hardware_memory = {}
        hardware_os = hardware_metadata.get("os")
        if not isinstance(hardware_os, dict):
            hardware_os = {}
        model = short_model_name(
            str(record.get("model_file") or record.get("model") or record.get("name") or "unknown-model")
        )
        threads = integerish(record.get("threads_requested"))
        if threads is None:
            threads = integerish(record.get("threads"))
        if threads is None:
            threads = integerish(record.get("n_threads"))

        row = {
            "run_id": record.get("run_id") or "",
            "test_device": test_metadata.get("device"),
            "ambient_c": number(test_metadata.get("ambient_c")),
            "cpu_tdp_w": number(test_metadata.get("cpu_tdp_w")),
            "mount_orientation": test_metadata.get("mount_orientation"),
            "clearance": test_metadata.get("clearance"),
            "external_fan": test_metadata.get("external_fan"),
            "hardware_product": hardware_system.get("product_name"),
            "hardware_board": hardware_system.get("board_name"),
            "bios_version": hardware_system.get("bios_version"),
            "os_pretty_name": hardware_os.get("pretty_name"),
            "kernel": hardware_os.get("kernel"),
            "cpu_model": hardware_cpu.get("model"),
            "cpu_vendor": hardware_cpu.get("vendor"),
            "logical_cpus": number(hardware_cpu.get("logical_cpus")),
            "cpu_cores_per_socket": number(hardware_cpu.get("cores_per_socket")),
            "cpu_threads_per_core": number(hardware_cpu.get("threads_per_core")),
            "cpu_max_mhz": number(hardware_cpu.get("max_mhz")),
            "memory_total_gb": number(hardware_memory.get("total_gb")),
            "model": model,
            "threads": threads,
            "type": str(record.get("type") or "benchmark"),
            "avg_ts": number(record.get("avg_ts")),
            "stddev_ts": number(record.get("stddev_ts")),
            "before_max_c": number(nested(record, "cpu_thermal_before", "max_c")),
            "before_avg_c": number(nested(record, "cpu_thermal_before", "avg_c")),
            "during_max_c": number(nested(record, "cpu_thermal_during", "max_c")),
            "during_avg_c": number(nested(record, "cpu_thermal_during", "avg_c")),
            "after_max_c": number(nested(record, "cpu_thermal_after", "max_c")),
            "after_avg_c": number(nested(record, "cpu_thermal_after", "avg_c")),
            "thermal_samples": integerish(nested(record, "cpu_thermal_during", "sample_count")),
            "stabilized": nested(record, "cpu_thermal_stabilization", "stable"),
            "stabilization_reason": nested(record, "cpu_thermal_stabilization", "reason"),
            "stabilization_waited_seconds": number(
                nested(record, "cpu_thermal_stabilization", "waited_seconds")
            ),
            "stabilization_final_max_c": number(
                nested(record, "cpu_thermal_stabilization", "final_max_c")
            ),
            "stabilization_started_at": nested(
                record, "cpu_thermal_stabilization", "started_at_utc"
            ),
            "thermal_before_at": nested(record, "cpu_thermal_before", "sampled_at_utc"),
            "thermal_during_started_at": nested(record, "cpu_thermal_during", "started_at_utc"),
            "thermal_during_ended_at": nested(record, "cpu_thermal_during", "ended_at_utc"),
            "thermal_after_at": nested(record, "cpu_thermal_after", "sampled_at_utc"),
            "raw": record,
        }
        normalised.append(row)
    return normalised


def aggregate_throughput(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, int | None, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        if row["avg_ts"] is not None:
            grouped[(row["model"], row["threads"], row["type"])].append(row)

    aggregated: list[dict[str, Any]] = []
    for (model, threads, bench_type), items in grouped.items():
        aggregated.append(
            {
                "model": model,
                "threads": threads,
                "type": bench_type,
                "avg_ts": mean_or_none(item["avg_ts"] for item in items),
                "stddev_ts": mean_or_none(item["stddev_ts"] for item in items),
                "during_max_c": max_or_none(item["during_max_c"] for item in items),
                "during_avg_c": mean_or_none(item["during_avg_c"] for item in items),
                "before_max_c": mean_or_none(item["before_max_c"] for item in items),
                "after_max_c": mean_or_none(item["after_max_c"] for item in items),
                "ambient_c": mean_or_none(item["ambient_c"] for item in items),
                "cpu_tdp_w": mean_or_none(item["cpu_tdp_w"] for item in items),
                "test_device": next(
                    (item["test_device"] for item in items if item.get("test_device")),
                    None,
                ),
                "hardware_product": next(
                    (item["hardware_product"] for item in items if item.get("hardware_product")),
                    None,
                ),
                "cpu_model": next(
                    (item["cpu_model"] for item in items if item.get("cpu_model")),
                    None,
                ),
                "logical_cpus": mean_or_none(item["logical_cpus"] for item in items),
                "memory_total_gb": mean_or_none(item["memory_total_gb"] for item in items),
                "stabilization_waited_seconds": mean_or_none(
                    item["stabilization_waited_seconds"] for item in items
                ),
                "stabilization_timed_out": any(
                    item["stabilization_reason"] == "timeout" for item in items
                ),
                "stabilization_reason": ", ".join(
                    sorted(
                        {
                            str(item["stabilization_reason"])
                            for item in items
                            if item.get("stabilization_reason")
                        }
                    )
                ),
                "count": len(items),
            }
        )

    return sorted(
        aggregated,
        key=lambda row: (
            row["type"],
            row["model"],
            -1 if row["threads"] is None else row["threads"],
        ),
    )


def aggregate_invocations(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: dict[tuple[Any, ...], dict[str, Any]] = {}
    for row in rows:
        signature = (
            row["run_id"],
            row["model"],
            row["threads"],
            row["thermal_before_at"],
            row["thermal_during_started_at"],
            row["thermal_during_ended_at"],
            row["thermal_after_at"],
        )
        if signature in seen:
            continue
        seen[signature] = {
            "run_id": row["run_id"],
            "test_device": row["test_device"],
            "ambient_c": row["ambient_c"],
            "cpu_tdp_w": row["cpu_tdp_w"],
            "hardware_product": row["hardware_product"],
            "cpu_model": row["cpu_model"],
            "logical_cpus": row["logical_cpus"],
            "memory_total_gb": row["memory_total_gb"],
            "model": row["model"],
            "threads": row["threads"],
            "label": config_label(row),
            "before_max_c": row["before_max_c"],
            "during_max_c": row["during_max_c"],
            "during_avg_c": row["during_avg_c"],
            "after_max_c": row["after_max_c"],
            "thermal_samples": row["thermal_samples"],
            "stabilized": row["stabilized"],
            "stabilization_reason": row["stabilization_reason"],
            "stabilization_waited_seconds": row["stabilization_waited_seconds"],
            "stabilization_final_max_c": row["stabilization_final_max_c"],
        }
    return list(seen.values())


def config_label(row: dict[str, Any]) -> str:
    threads = row.get("threads")
    suffix = f"{threads} threads" if threads is not None else "threads unknown"
    return f"{row.get('model', 'unknown')} | {suffix}"


def choose_primary_type(throughput_rows: list[dict[str, Any]], requested: str) -> str | None:
    types = sorted({str(row["type"]) for row in throughput_rows if row.get("type")})
    if not types:
        return None
    if requested != "auto":
        return requested
    if "tg" in types:
        return "tg"
    if "generation" in types:
        return "generation"
    return types[0]


def score_sustained_use(
    throughput_rows: list[dict[str, Any]], primary_type: str | None, thermal_limit_c: float
) -> list[dict[str, Any]]:
    candidates = [
        row.copy()
        for row in throughput_rows
        if row.get("avg_ts") is not None and (primary_type is None or row.get("type") == primary_type)
    ]
    if not candidates:
        return []

    fastest = max(float(row["avg_ts"]) for row in candidates if row.get("avg_ts") is not None)
    if fastest <= 0:
        fastest = 1.0

    for row in candidates:
        avg_ts = number(row.get("avg_ts"))
        stddev_ts = number(row.get("stddev_ts"))
        peak_c = number(row.get("during_max_c"))
        before_c = number(row.get("before_max_c"))
        wait_s = number(row.get("stabilization_waited_seconds"))
        timed_out = bool(row.get("stabilization_timed_out"))

        cv = None
        if avg_ts is not None and avg_ts > 0 and stddev_ts is not None:
            cv = stddev_ts / avg_ts

        temp_rise_c = None
        if peak_c is not None and before_c is not None:
            temp_rise_c = peak_c - before_c

        throughput_component = clamp((avg_ts or 0.0) / fastest)
        variance_component = clamp(1.0 - ((cv if cv is not None else 0.05) / 0.10))

        if peak_c is None:
            thermal_headroom_component = 0.50
            thermal_headroom_c = None
        else:
            thermal_headroom_c = thermal_limit_c - peak_c
            thermal_headroom_component = clamp(
                (thermal_limit_c - peak_c) / max(1.0, thermal_limit_c - 45.0)
            )

        if temp_rise_c is None:
            thermal_rise_component = 0.50
        else:
            thermal_rise_component = clamp(1.0 - max(0.0, temp_rise_c) / 25.0)

        if timed_out:
            cooldown_component = 0.0
        elif wait_s is None:
            cooldown_component = 0.50
        else:
            cooldown_component = clamp(1.0 - wait_s / 300.0)

        sustained_score = 100.0 * (
            0.35 * throughput_component
            + 0.20 * variance_component
            + 0.25 * thermal_headroom_component
            + 0.10 * thermal_rise_component
            + 0.10 * cooldown_component
        )

        row.update(
            {
                "cv_pct": None if cv is None else cv * 100.0,
                "temp_rise_c": temp_rise_c,
                "thermal_headroom_c": thermal_headroom_c,
                "throughput_component": throughput_component,
                "variance_component": variance_component,
                "thermal_headroom_component": thermal_headroom_component,
                "thermal_rise_component": thermal_rise_component,
                "cooldown_component": cooldown_component,
                "sustained_score": sustained_score,
                "thermal_limit_c": thermal_limit_c,
            }
        )

    return sorted(candidates, key=lambda row: row["sustained_score"], reverse=True)


def color_for(value: str) -> str:
    index = sum(ord(ch) for ch in value) % len(PALETTE)
    return PALETTE[index]


def truncate(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 3)] + "..."


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def nice_max(value: float) -> float:
    if value <= 0:
        return 1.0
    exponent = math.floor(math.log10(value))
    fraction = value / (10**exponent)
    if fraction <= 1:
        nice = 1
    elif fraction <= 2:
        nice = 2
    elif fraction <= 5:
        nice = 5
    else:
        nice = 10
    return nice * (10**exponent)


def svg_text(x: float, y: float, text: str, size: int = 14, anchor: str = "start", weight: str = "400") -> str:
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" '
        f'font-weight="{weight}" text-anchor="{anchor}" fill="#1f2933">{esc(text)}</text>'
    )


def write_svg(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")


def render_empty_svg(path: Path, title: str, message: str) -> None:
    width = 1100
    height = 360
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<rect width="100%" height="100%" fill="#ffffff"/>
{svg_text(48, 64, title, 28, weight="700")}
{svg_text(48, 118, message, 18)}
</svg>
"""
    write_svg(path, svg)


def render_bar_chart(
    path: Path,
    title: str,
    subtitle: str,
    rows: list[dict[str, Any]],
    value_key: str,
    unit: str,
    max_bars: int,
) -> None:
    rows = [row for row in rows if number(row.get(value_key)) is not None]
    rows = sorted(rows, key=lambda row: number(row[value_key]) or 0, reverse=True)[:max_bars]
    if not rows:
        render_empty_svg(path, title, "No data available for this figure.")
        return

    width = 1180
    left = 365
    right = 120
    top = 118
    row_h = 34
    bottom = 74
    height = top + row_h * len(rows) + bottom
    plot_w = width - left - right
    max_value = nice_max(max(number(row[value_key]) or 0 for row in rows) * 1.08)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        svg_text(36, 48, title, 26, weight="700"),
        svg_text(36, 78, subtitle, 14),
        f'<line x1="{left}" y1="{top - 12}" x2="{left}" y2="{height - bottom + 16}" stroke="#d6dce2"/>',
        f'<line x1="{left}" y1="{height - bottom + 16}" x2="{width - right}" y2="{height - bottom + 16}" stroke="#d6dce2"/>',
    ]

    for tick in range(5):
        value = max_value * tick / 4
        x = left + plot_w * tick / 4
        parts.append(f'<line x1="{x:.1f}" y1="{top - 12}" x2="{x:.1f}" y2="{height - bottom + 16}" stroke="#eef1f4"/>')
        parts.append(svg_text(x, height - bottom + 40, fmt(value), 12, anchor="middle"))

    for index, row in enumerate(rows):
        value = number(row[value_key]) or 0
        y = top + index * row_h
        bar_w = 0 if max_value == 0 else plot_w * value / max_value
        label = config_label(row)
        if row.get("type"):
            label = f"{label} | {row['type']}"
        color = color_for(str(row.get("model") or label))
        parts.append(svg_text(36, y + 20, truncate(label, 48), 13))
        parts.append(f'<rect x="{left}" y="{y}" width="{bar_w:.1f}" height="22" rx="3" fill="{color}"/>')
        parts.append(svg_text(left + bar_w + 8, y + 17, f"{fmt(value)} {unit}".strip(), 12))

    parts.append(svg_text(left + plot_w / 2, height - 18, unit, 13, anchor="middle"))
    parts.append("</svg>")
    write_svg(path, "\n".join(parts))


def render_thread_line_chart(
    path: Path,
    title: str,
    subtitle: str,
    rows: list[dict[str, Any]],
    unit: str,
) -> None:
    rows = [row for row in rows if row.get("threads") is not None and row.get("avg_ts") is not None]
    if not rows:
        render_empty_svg(path, title, "No thread scaling data available for this figure.")
        return

    series: dict[str, list[tuple[int, float]]] = defaultdict(list)
    for row in rows:
        series[row["model"]].append((int(row["threads"]), float(row["avg_ts"])))

    series = {name: sorted(points) for name, points in series.items() if points}
    threads = sorted({thread for points in series.values() for thread, _ in points})
    values = [value for points in series.values() for _, value in points]
    if not threads or not values:
        render_empty_svg(path, title, "No thread scaling data available for this figure.")
        return

    width = 1180
    height = 640
    left = 86
    right = 260
    top = 104
    bottom = 86
    plot_w = width - left - right
    plot_h = height - top - bottom
    y_max = nice_max(max(values) * 1.12)
    x_min = min(threads)
    x_max = max(threads)
    if x_min == x_max:
        x_min -= 1
        x_max += 1

    def x_pos(thread: int) -> float:
        return left + ((thread - x_min) / (x_max - x_min)) * plot_w

    def y_pos(value: float) -> float:
        return top + plot_h - (value / y_max) * plot_h

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        svg_text(36, 48, title, 26, weight="700"),
        svg_text(36, 78, subtitle, 14),
        f'<rect x="{left}" y="{top}" width="{plot_w}" height="{plot_h}" fill="#fbfcfd" stroke="#d6dce2"/>',
    ]

    for tick in range(6):
        value = y_max * tick / 5
        y = y_pos(value)
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{left + plot_w}" y2="{y:.1f}" stroke="#edf1f5"/>')
        parts.append(svg_text(left - 10, y + 4, fmt(value), 12, anchor="end"))

    for thread in threads:
        x = x_pos(thread)
        parts.append(f'<line x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{top + plot_h}" stroke="#f1f4f7"/>')
        parts.append(svg_text(x, top + plot_h + 28, str(thread), 12, anchor="middle"))

    legend_y = top
    for index, (model, points) in enumerate(series.items()):
        color = color_for(model)
        path_points = " ".join(f"{x_pos(thread):.1f},{y_pos(value):.1f}" for thread, value in points)
        parts.append(f'<polyline points="{path_points}" fill="none" stroke="{color}" stroke-width="3"/>')
        for thread, value in points:
            x = x_pos(thread)
            y = y_pos(value)
            parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4.5" fill="{color}"><title>{esc(model)}: {thread} threads, {fmt(value)} {esc(unit)}</title></circle>')
        if index < 12:
            y = legend_y + index * 24
            parts.append(f'<rect x="{left + plot_w + 34}" y="{y - 10}" width="14" height="14" fill="{color}"/>')
            parts.append(svg_text(left + plot_w + 56, y + 2, truncate(model, 28), 12))

    parts.append(svg_text(left + plot_w / 2, height - 28, "Threads", 13, anchor="middle"))
    parts.append(svg_text(22, top + plot_h / 2, unit, 13, anchor="middle"))
    parts.append("</svg>")
    write_svg(path, "\n".join(parts))


def render_scatter_chart(
    path: Path,
    title: str,
    subtitle: str,
    rows: list[dict[str, Any]],
) -> None:
    points = [
        row
        for row in rows
        if row.get("avg_ts") is not None and row.get("during_max_c") is not None
    ]
    if not points:
        render_empty_svg(path, title, "No combined throughput and thermal data available for this figure.")
        return

    x_values = [float(row["during_max_c"]) for row in points]
    y_values = [float(row["avg_ts"]) for row in points]
    x_min = math.floor(min(x_values) - 2)
    x_max = math.ceil(max(x_values) + 2)
    y_min = 0.0
    y_max = nice_max(max(y_values) * 1.12)
    if x_min == x_max:
        x_min -= 1
        x_max += 1

    width = 1180
    height = 660
    left = 92
    right = 270
    top = 104
    bottom = 88
    plot_w = width - left - right
    plot_h = height - top - bottom

    def x_pos(value: float) -> float:
        return left + ((value - x_min) / (x_max - x_min)) * plot_w

    def y_pos(value: float) -> float:
        return top + plot_h - ((value - y_min) / (y_max - y_min)) * plot_h

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        svg_text(36, 48, title, 26, weight="700"),
        svg_text(36, 78, subtitle, 14),
        f'<rect x="{left}" y="{top}" width="{plot_w}" height="{plot_h}" fill="#fbfcfd" stroke="#d6dce2"/>',
    ]

    for tick in range(6):
        y_value = y_max * tick / 5
        y = y_pos(y_value)
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{left + plot_w}" y2="{y:.1f}" stroke="#edf1f5"/>')
        parts.append(svg_text(left - 10, y + 4, fmt(y_value), 12, anchor="end"))

        x_value = x_min + (x_max - x_min) * tick / 5
        x = x_pos(x_value)
        parts.append(f'<line x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{top + plot_h}" stroke="#f1f4f7"/>')
        parts.append(svg_text(x, top + plot_h + 28, fmt(x_value), 12, anchor="middle"))

    models_seen: list[str] = []
    for row in points:
        model = row["model"]
        if model not in models_seen:
            models_seen.append(model)
        x = x_pos(float(row["during_max_c"]))
        y = y_pos(float(row["avg_ts"]))
        radius = 5 + min(9, (row.get("threads") or 1) ** 0.5)
        color = color_for(model)
        parts.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{radius:.1f}" fill="{color}" fill-opacity="0.86" stroke="#ffffff" stroke-width="1.5">'
            f'<title>{esc(config_label(row))}: {fmt(row["avg_ts"])} tok/s at {fmt(row["during_max_c"])} C</title></circle>'
        )

    for index, model in enumerate(models_seen[:12]):
        y = top + index * 24
        parts.append(f'<rect x="{left + plot_w + 34}" y="{y - 10}" width="14" height="14" fill="{color_for(model)}"/>')
        parts.append(svg_text(left + plot_w + 56, y + 2, truncate(model, 28), 12))

    parts.append(svg_text(left + plot_w / 2, height - 28, "Peak CPU temperature during run (C)", 13, anchor="middle"))
    parts.append(svg_text(24, top + plot_h / 2, "Throughput (tokens/sec)", 13, anchor="middle"))
    parts.append("</svg>")
    write_svg(path, "\n".join(parts))


def write_csv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})


def make_metric_cards(
    rows: list[dict[str, Any]],
    throughput_rows: list[dict[str, Any]],
    invocations: list[dict[str, Any]],
    sustained_rows: list[dict[str, Any]],
    primary_type: str | None,
) -> list[tuple[str, str]]:
    models = sorted({row["model"] for row in rows})
    threads = sorted({row["threads"] for row in rows if row["threads"] is not None})
    types = sorted({row["type"] for row in rows})
    peak_temp = max_or_none(row.get("during_max_c") for row in invocations)
    ambient = mean_or_none(row.get("ambient_c") for row in rows)
    devices = sorted({str(row["test_device"]) for row in rows if row.get("test_device")})
    products = sorted({str(row["hardware_product"]) for row in rows if row.get("hardware_product")})
    cpu_models = sorted({str(row["cpu_model"]) for row in rows if row.get("cpu_model")})
    memory_total = mean_or_none(row.get("memory_total_gb") for row in rows)
    top_sustained = sustained_rows[0] if sustained_rows else None
    best_by_type = []
    for bench_type in types:
        typed = [row for row in throughput_rows if row["type"] == bench_type and row["avg_ts"] is not None]
        if typed:
            best = max(typed, key=lambda row: row["avg_ts"])
            best_by_type.append(f"{bench_type}: {fmt(best['avg_ts'])}")

    return [
        ("Records", str(len(rows))),
        ("Device", ", ".join(devices) if devices else "not captured"),
        ("Hardware", ", ".join(products) if products else "not captured"),
        ("CPU", ", ".join(cpu_models) if cpu_models else "not captured"),
        ("Memory", f"{fmt(memory_total)} GB" if memory_total is not None else "not captured"),
        ("Models", str(len(models))),
        ("Thread Counts", ", ".join(str(thread) for thread in threads) or "unknown"),
        ("Benchmark Types", ", ".join(types) or "unknown"),
        ("Primary Type", primary_type or "unknown"),
        ("Ambient", f"{fmt(ambient)} C" if ambient is not None else "not captured"),
        ("Peak CPU Temp", f"{fmt(peak_temp)} C" if peak_temp is not None else "not captured"),
        ("Best Throughput", "; ".join(best_by_type) or "not available"),
        (
            "Top Sustained Pick",
            f"{config_label(top_sustained)} ({fmt(top_sustained['sustained_score'])})"
            if top_sustained
            else "not available",
        ),
    ]


def table_html(headers: list[str], rows: list[list[Any]]) -> str:
    head = "".join(f"<th>{esc(header)}</th>" for header in headers)
    body_rows = []
    for row in rows:
        body_rows.append("<tr>" + "".join(f"<td>{esc(cell)}</td>" for cell in row) + "</tr>")
    return f"<table><thead><tr>{head}</tr></thead><tbody>{''.join(body_rows)}</tbody></table>"


def build_dashboard_html(
    title: str,
    input_path: Path,
    output_dir: Path,
    figures: list[dict[str, str]],
    rows: list[dict[str, Any]],
    throughput_rows: list[dict[str, Any]],
    invocations: list[dict[str, Any]],
    sustained_rows: list[dict[str, Any]],
    primary_type: str | None,
    thermal_limit_c: float,
) -> str:
    generated_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    run_ids = sorted({str(row["run_id"]) for row in rows if row.get("run_id")})
    cards = make_metric_cards(rows, throughput_rows, invocations, sustained_rows, primary_type)

    best_rows: list[list[Any]] = []
    for bench_type in sorted({row["type"] for row in throughput_rows}):
        typed = [row for row in throughput_rows if row["type"] == bench_type and row["avg_ts"] is not None]
        for row in sorted(typed, key=lambda item: item["avg_ts"] or 0, reverse=True)[:8]:
            best_rows.append(
                [
                    row["type"],
                    row["model"],
                    row["threads"] if row["threads"] is not None else "",
                    fmt(row["avg_ts"]),
                    fmt(row["stddev_ts"]),
                    fmt(row["during_max_c"]),
                ]
            )

    thermal_rows = [
        [
            row["model"],
            row["threads"] if row["threads"] is not None else "",
            fmt(row["before_max_c"]),
            fmt(row["during_max_c"]),
            fmt(row["after_max_c"]),
            fmt(row["stabilization_waited_seconds"]),
            row["stabilization_reason"] or "",
        ]
        for row in invocations
        if row.get("during_max_c") is not None or row.get("stabilization_reason")
    ]

    sustained_table_rows = [
        [
            rank,
            row["model"],
            row["threads"] if row["threads"] is not None else "",
            fmt(row["sustained_score"]),
            fmt(row["avg_ts"]),
            fmt(row["cv_pct"]),
            fmt(row["during_max_c"]),
            fmt(row["thermal_headroom_c"]),
            fmt(row["temp_rise_c"]),
            fmt(row["stabilization_waited_seconds"]),
            row["stabilization_reason"] or "",
        ]
        for rank, row in enumerate(sustained_rows[:20], start=1)
    ]

    card_html = "".join(
        f'<div class="metric"><div class="metric-label">{esc(label)}</div><div class="metric-value">{esc(value)}</div></div>'
        for label, value in cards
    )
    figure_html = "".join(
        f"""
        <section class="figure-block">
            <div class="figure-title">
                <h2>{esc(figure["title"])}</h2>
                <a href="{esc(figure["href"])}">Open SVG</a>
            </div>
            <img src="{esc(figure["href"])}" alt="{esc(figure["title"])}">
        </section>
        """
        for figure in figures
    )

    best_table = table_html(
        ["Type", "Model", "Threads", "Avg tok/s", "Stddev", "Peak CPU C"],
        best_rows,
    )
    sustained_table = table_html(
        [
            "Rank",
            "Model",
            "Threads",
            "Score",
            "Avg tok/s",
            "CV %",
            "Peak CPU C",
            "Headroom C",
            "Rise C",
            "Wait s",
            "Stabilize Reason",
        ],
        sustained_table_rows,
    )
    thermal_table = table_html(
        ["Model", "Threads", "Before C", "Peak C", "After C", "Stabilize Wait s", "Stabilize Reason"],
        thermal_rows,
    )

    relative_input = os.path.relpath(input_path, output_dir)
    run_text = ", ".join(run_ids) if run_ids else "not present in JSON"

    return f"""<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{esc(title)}</title>
    <style>
        :root {{
            color-scheme: light;
            --ink: #1f2933;
            --muted: #5d6b78;
            --line: #d9e0e7;
            --panel: #ffffff;
            --bg: #f5f7f9;
            --accent: #276a73;
        }}
        * {{ box-sizing: border-box; }}
        body {{
            margin: 0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            color: var(--ink);
            background: var(--bg);
        }}
        header {{
            padding: 32px 40px 22px;
            background: #ffffff;
            border-bottom: 1px solid var(--line);
        }}
        h1 {{
            margin: 0 0 10px;
            font-size: 30px;
            letter-spacing: 0;
        }}
        .subtle {{
            margin: 4px 0;
            color: var(--muted);
            font-size: 14px;
        }}
        main {{
            max-width: 1360px;
            margin: 0 auto;
            padding: 28px 28px 56px;
        }}
        .metrics {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 12px;
            margin-bottom: 24px;
        }}
        .metric, .figure-block, .table-block {{
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 8px;
        }}
        .metric {{
            padding: 16px;
            min-height: 92px;
        }}
        .metric-label {{
            color: var(--muted);
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: .04em;
        }}
        .metric-value {{
            margin-top: 10px;
            font-size: 22px;
            font-weight: 700;
        }}
        .figure-block {{
            margin: 18px 0;
            padding: 18px;
        }}
        .figure-title {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 16px;
            margin-bottom: 10px;
        }}
        h2 {{
            margin: 0;
            font-size: 18px;
        }}
        a {{
            color: var(--accent);
            text-decoration: none;
            font-weight: 600;
        }}
        img {{
            display: block;
            width: 100%;
            height: auto;
            border: 1px solid #eef1f4;
            border-radius: 6px;
            background: #ffffff;
        }}
        .table-block {{
            margin-top: 24px;
            padding: 18px;
            overflow-x: auto;
        }}
        table {{
            width: 100%;
            border-collapse: collapse;
            font-size: 13px;
        }}
        th, td {{
            padding: 9px 10px;
            border-bottom: 1px solid #edf1f5;
            text-align: left;
            vertical-align: top;
        }}
        th {{
            color: var(--muted);
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: .04em;
            background: #fbfcfd;
        }}
        .note {{
            margin: 0 0 20px;
            color: var(--muted);
            line-height: 1.5;
        }}
    </style>
</head>
<body>
    <header>
        <h1>{esc(title)}</h1>
        <p class="subtle">Run ID: {esc(run_text)}</p>
        <p class="subtle">Input: {esc(relative_input)}</p>
        <p class="subtle">Generated: {esc(generated_at)}</p>
    </header>
    <main>
        <p class="note">This dashboard ranks model/thread configurations for unattended fanless operation on OnLogic K802 industrial PCs. The sustained score uses {esc(primary_type or "the selected")} throughput, throughput variance, CPU thermal headroom against {esc(fmt(thermal_limit_c))} C, temperature rise, and stabilization wait time. Standalone figure files are in the <strong>figures</strong> folder next to this dashboard.</p>
        <section class="metrics">{card_html}</section>
        {figure_html}
        <section class="table-block">
            <h2>Sustained Use Ranking</h2>
            {sustained_table}
        </section>
        <section class="table-block">
            <h2>Best Results</h2>
            {best_table}
        </section>
        <section class="table-block">
            <h2>Thermal Summary</h2>
            {thermal_table}
        </section>
    </main>
</body>
</html>
"""


def generate_dashboard(
    input_path: Path,
    output_dir: Path,
    title: str,
    max_bars: int,
    thermal_limit_c: float,
    requested_primary_type: str,
) -> None:
    records = load_records(input_path)
    if not records:
        raise SystemExit(f"No benchmark records found in {input_path}")

    rows = normalise_records(records)
    throughput_rows = aggregate_throughput(rows)
    invocations = aggregate_invocations(rows)
    primary_type = choose_primary_type(throughput_rows, requested_primary_type)
    sustained_rows = score_sustained_use(throughput_rows, primary_type, thermal_limit_c)

    output_dir.mkdir(parents=True, exist_ok=True)
    figures_dir = output_dir / "figures"
    figures_dir.mkdir(parents=True, exist_ok=True)

    figures: list[dict[str, str]] = []
    benchmark_types = sorted({row["type"] for row in throughput_rows})

    sustained_path = figures_dir / "sustained-use-ranking.svg"
    render_bar_chart(
        sustained_path,
        "Sustained Use Ranking",
        "Composite score for unattended fanless operation: throughput, variance, thermal headroom, temperature rise, and cooldown wait.",
        sustained_rows,
        "sustained_score",
        "score",
        max_bars,
    )
    figures.append({"title": "Sustained Use Ranking", "href": f"figures/{sustained_path.name}"})

    for bench_type in benchmark_types:
        typed = [row for row in throughput_rows if row["type"] == bench_type]
        path = figures_dir / f"throughput-{slugify(bench_type)}.svg"
        render_bar_chart(
            path,
            f"Throughput: {bench_type}",
            "Higher is better. Bars show averaged llama-bench tokens/sec by model and thread count.",
            typed,
            "avg_ts",
            "tok/s",
            max_bars,
        )
        figures.append({"title": f"Throughput: {bench_type}", "href": f"figures/{path.name}"})

        line_path = figures_dir / f"thread-scaling-{slugify(bench_type)}.svg"
        render_thread_line_chart(
            line_path,
            f"Thread Scaling: {bench_type}",
            "Throughput by thread count for each model.",
            typed,
            "tokens/sec",
        )
        figures.append({"title": f"Thread Scaling: {bench_type}", "href": f"figures/{line_path.name}"})

    thermal_chart_rows = [
        {"model": row["model"], "threads": row["threads"], "during_max_c": row["during_max_c"]}
        for row in invocations
    ]
    peak_temp_path = figures_dir / "cpu-peak-temperature.svg"
    render_bar_chart(
        peak_temp_path,
        "Peak CPU Temperature",
        "Maximum CPU temperature sampled while each benchmark invocation was running.",
        thermal_chart_rows,
        "during_max_c",
        "C",
        max_bars,
    )
    figures.append({"title": "Peak CPU Temperature", "href": f"figures/{peak_temp_path.name}"})

    wait_chart_rows = [
        {
            "model": row["model"],
            "threads": row["threads"],
            "stabilization_waited_seconds": row["stabilization_waited_seconds"],
        }
        for row in invocations
    ]
    wait_path = figures_dir / "cpu-stabilization-wait.svg"
    render_bar_chart(
        wait_path,
        "CPU Temperature Stabilization Wait",
        "Seconds spent waiting for CPU temperature to settle before each benchmark invocation.",
        wait_chart_rows,
        "stabilization_waited_seconds",
        "s",
        max_bars,
    )
    figures.append({"title": "CPU Temperature Stabilization Wait", "href": f"figures/{wait_path.name}"})

    scatter_rows = [
        row
        for row in throughput_rows
        if primary_type is None or row["type"] == primary_type
    ]
    scatter_path = figures_dir / "throughput-vs-cpu-temperature.svg"
    render_scatter_chart(
        scatter_path,
        "Throughput vs CPU Temperature",
        "Each point is one model/thread configuration. Point size increases with thread count.",
        scatter_rows,
    )
    figures.append({"title": "Throughput vs CPU Temperature", "href": f"figures/{scatter_path.name}"})

    write_csv(
        output_dir / "benchmark-summary.csv",
        throughput_rows,
        [
            "model",
            "threads",
            "type",
            "avg_ts",
            "stddev_ts",
            "test_device",
            "hardware_product",
            "cpu_model",
            "logical_cpus",
            "memory_total_gb",
            "ambient_c",
            "cpu_tdp_w",
            "before_max_c",
            "during_max_c",
            "during_avg_c",
            "after_max_c",
            "stabilization_waited_seconds",
            "stabilization_timed_out",
            "stabilization_reason",
            "count",
        ],
    )
    write_csv(
        output_dir / "sustained-use-ranking.csv",
        sustained_rows,
        [
            "model",
            "threads",
            "type",
            "sustained_score",
            "avg_ts",
            "stddev_ts",
            "cv_pct",
            "test_device",
            "hardware_product",
            "cpu_model",
            "logical_cpus",
            "memory_total_gb",
            "ambient_c",
            "cpu_tdp_w",
            "before_max_c",
            "during_max_c",
            "during_avg_c",
            "after_max_c",
            "temp_rise_c",
            "thermal_headroom_c",
            "stabilization_waited_seconds",
            "stabilization_timed_out",
            "stabilization_reason",
            "thermal_limit_c",
        ],
    )
    write_csv(
        output_dir / "thermal-summary.csv",
        invocations,
        [
            "model",
            "threads",
            "test_device",
            "hardware_product",
            "cpu_model",
            "logical_cpus",
            "memory_total_gb",
            "ambient_c",
            "cpu_tdp_w",
            "before_max_c",
            "during_max_c",
            "during_avg_c",
            "after_max_c",
            "thermal_samples",
            "stabilized",
            "stabilization_reason",
            "stabilization_waited_seconds",
            "stabilization_final_max_c",
        ],
    )

    manifest_rows = [{"title": figure["title"], "file": figure["href"]} for figure in figures]
    write_csv(output_dir / "figure-manifest.csv", manifest_rows, ["title", "file"])

    html_text = build_dashboard_html(
        title,
        input_path,
        output_dir,
        figures,
        rows,
        throughput_rows,
        invocations,
        sustained_rows,
        primary_type,
        thermal_limit_c,
    )
    (output_dir / "index.html").write_text(html_text, encoding="utf-8")

    print(f"[+] Dashboard written to: {output_dir / 'index.html'}")
    print(f"[+] Figures written to: {figures_dir}")


def main() -> None:
    args = parse_args()
    input_path = Path(args.input_json).expanduser().resolve()
    if not input_path.exists():
        raise SystemExit(f"Input file not found: {input_path}")

    if args.output_dir:
        output_dir = Path(args.output_dir).expanduser().resolve()
    else:
        output_dir = input_path.parent / "dashboard"

    generate_dashboard(
        input_path,
        output_dir,
        args.title,
        args.max_bars,
        args.thermal_limit_c,
        args.primary_type,
    )


if __name__ == "__main__":
    main()
