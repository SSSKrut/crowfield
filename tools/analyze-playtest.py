#!/usr/bin/env python3
"""Summarize input timing from a local Crowfield playtest run."""

import argparse
import json
import math
from pathlib import Path
from statistics import median


LATEST = Path.home() / "Library/Application Support/Godot/app_userdata/Crowfield/playtests/latest"
MOVEMENT = ("move_forward", "move_back", "move_left", "move_right")


def read_trace(path):
    records = []
    malformed = 0
    with path.open(encoding="utf-8") as source:
        for line in source:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError("expected an object")
            except ValueError:
                malformed += 1
            else:
                records.append(row)
    return records, malformed


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def timing_summary(values):
    ordered = sorted(values)
    p95 = ordered[math.ceil(0.95 * len(ordered)) - 1]
    slow = sum(value >= 50 for value in ordered)
    very_slow = sum(value >= 100 for value in ordered)
    return (
        f"n={len(ordered)}, median {median(ordered):.1f} ms, p95 {p95:.1f} ms, "
        f"max {ordered[-1]:.1f} ms, ≥50 ms {slow}, ≥100 ms {very_slow}"
    )


def dropped_records(records, marker):
    return sum(max(0, row["count"]) for row in records if row.get("type") == marker and type(row.get("count")) is int)


def movement_edge(row):
    return row.get("action"), row.get("pressed")


def valid_edge(row):
    action, pressed = movement_edge(row)
    return action in MOVEMENT and type(pressed) is bool


def describe_edge(row):
    action, pressed = movement_edge(row)
    return f"{action.removeprefix('move_')} {'down' if pressed else 'up'}"


def relative_time(row, anchor, field, origin):
    instant = row.get(field)
    if numeric(instant) and numeric(anchor):
        return f", {origin} {(instant - anchor) / 1_000_000:+.3f}s"
    return ""


def summarize_game(records, malformed):
    keys = [row for row in records if row.get("type") == "movement_key"]
    samples = [row for row in records if row.get("type") == "sample"]
    start = next((row.get("monotonic_usec") for row in records if row.get("type") == "run_start"), None)
    dropped = dropped_records(records, "records_dropped")
    print(f"Game trace: {len(keys)} movement edges, {len(samples)} state samples")
    if dropped or malformed:
        print(f"  Data gaps: {dropped} records dropped, {malformed} malformed lines")
    if not any(row.get("type") == "run_end" for row in records):
        print("  No run_end marker. The tail of the trace may be missing.")
    frame_samples = [row for row in samples if numeric(row.get("longest_frame_ms"))]
    if frame_samples:
        print("  Worst frame per sampled interval: " + timing_summary([row["longest_frame_ms"] for row in frame_samples]))
        outliers = [row for row in frame_samples if row["longest_frame_ms"] >= 50]
        for row in sorted(outliers, key=lambda row: row["longest_frame_ms"], reverse=True)[:3]:
            time = relative_time(row, start, "monotonic_usec", "game")
            print(f"    {row['longest_frame_ms']:.1f} ms{time}, focus={row.get('window_focused', '?')}, captured={row.get('gameplay_captured', '?')}")
    return keys


def summarize_native(records, malformed):
    starts = [row for row in records if row.get("type") == "native_start"]
    status = starts[0].get("status", "unknown") if len(starts) == 1 else "unknown"
    start = starts[0].get("uptime_usec") if len(starts) == 1 else None
    keys = [row for row in records if row.get("type") == "native_movement_key"]
    repeats = [row for row in keys if row.get("repeat") is True]
    edges = [row for row in keys if row.get("repeat") is False]
    dropped = dropped_records(records, "native_records_dropped")
    print(f"Native trace ({status}): {len(edges)} movement edges, {len(repeats)} key repeats")
    if dropped or malformed or len(keys) != len(edges) + len(repeats):
        print(f"  Data gaps: {dropped} records dropped, {malformed} malformed lines, {len(keys) - len(edges) - len(repeats)} unknown repeat flags")
    if not any(row.get("type") == "native_end" for row in records):
        print("  No native_end marker. The tail of the trace may be missing.")
    for group, label in ((edges, "Movement edges"), (repeats, "Key repeats")):
        ages = [row for row in group if valid_edge(row) and numeric(row.get("age_usec")) and row["age_usec"] >= 0]
        if ages:
            print(f"  {label}, native event timestamp to AppKit receipt: " + timing_summary([row["age_usec"] / 1000 for row in ages]))
            outliers = [row for row in ages if row["age_usec"] >= 50_000]
            for row in sorted(outliers, key=lambda row: row["age_usec"], reverse=True)[:3]:
                time = relative_time(row, start, "received_uptime_usec", "native")
                print(f"    {row['age_usec'] / 1000:.1f} ms, {describe_edge(row)}{time}")
        if len(ages) < len(group):
            print(f"  {label}: {len(group) - len(ages)} missing, invalid or negative ages excluded.")
    return edges, len(keys) - len(edges) - len(repeats)


def compare_timing(game, native, game_keys, native_keys, uncertain):
    game_start = [row for row in game if row.get("type") == "run_start"]
    native_start = [row for row in native if row.get("type") == "native_start"]
    clean_end = any(row.get("type") == "run_end" for row in game) and any(row.get("type") == "native_end" for row in native)
    if uncertain or not clean_end:
        print("Native → Godot timing unavailable: trace has dropped, malformed or unfinished data.")
        return
    if len(game_start) != 1 or len(native_start) != 1 or native_start[0].get("status") != "active":
        print("Native → Godot timing unavailable: no unique active clock anchors.")
        return
    if len(game_keys) < 2 or list(map(movement_edge, game_keys)) != list(map(movement_edge, native_keys)):
        print("Native → Godot timing unavailable: movement edge sequences differ or have fewer than two events.")
        return
    game_anchor, native_anchor = game_start[0], native_start[0]
    valid_anchors = all(numeric(row.get(field)) for row, field in (
        (game_anchor, "wall_unix_ms"), (game_anchor, "monotonic_usec"),
        (native_anchor, "wall_unix_usec"), (native_anchor, "uptime_usec"),
    ))
    valid_game_times = all(valid_edge(row) and numeric(row.get("monotonic_usec")) for row in game_keys)
    valid_native_times = all(numeric(row.get("received_uptime_usec")) for row in native_keys)
    if not (valid_anchors and valid_game_times and valid_native_times):
        print("Native → Godot timing unavailable: missing or invalid timestamps.")
        return
    game_zero = int(game_anchor["wall_unix_ms"]) * 1000 - game_anchor["monotonic_usec"]
    native_zero = native_anchor["wall_unix_usec"] - native_anchor["uptime_usec"]
    delays = [
        (game_zero - native_zero + game_row["monotonic_usec"] - native_row["received_uptime_usec"]) / 1000
        for game_row, native_row in zip(game_keys, native_keys)
    ]
    if min(delays) < -10 or median(delays) > 250:
        print("Native → Godot timing unavailable: clock alignment implies a delay below −10 ms or a median above 250 ms.")
        return
    print("AppKit receipt → Godot movement edge, approximate wall-clock alignment: " + timing_summary(delays))
    for delay, row in sorted(zip(delays, game_keys), key=lambda entry: entry[0], reverse=True)[:3]:
        if delay >= 50:
            time = relative_time(row, game_anchor["monotonic_usec"], "monotonic_usec", "game")
            print(f"    {delay:.1f} ms, {describe_edge(row)}{time}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path, nargs="?", default=LATEST, help="run directory (default: latest macOS playtest)")
    args = parser.parse_args()
    run = args.run.expanduser().resolve()
    if not run.is_dir():
        parser.exit(1, f"Run directory not found: {run}\n")
    print(f"Playtest {run.name}")
    try:
        records, malformed = read_trace(run / "gameplay.jsonl")
    except FileNotFoundError:
        records, malformed = [], 0
        print("Game trace unavailable: gameplay.jsonl was not recorded.")
    except OSError as error:
        parser.exit(1, f"Cannot read game trace: {error.strerror}\n")
    game_keys = summarize_game(records, malformed) if records or malformed else []
    try:
        native, native_malformed = read_trace(run / "native-input.jsonl")
    except FileNotFoundError:
        print("Native trace unavailable: native-input.jsonl was not recorded.")
        return
    except OSError as error:
        parser.exit(1, f"Cannot read native trace: {error.strerror}\n")
    native_keys, unknown_repeats = summarize_native(native, native_malformed)
    if not records:
        print("Native → Godot timing unavailable: no game records.")
        return
    unreliable = malformed or native_malformed or unknown_repeats or dropped_records(records, "records_dropped") or dropped_records(native, "native_records_dropped")
    compare_timing(records, native, game_keys, native_keys, unreliable)


if __name__ == "__main__":
    main()
