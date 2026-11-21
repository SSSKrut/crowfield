#!/usr/bin/env bash
# Start a comparative Valley round using a standalone macOS export.
set -euo pipefail

launcher_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
candidate="${1:-$launcher_dir/Crowfield.app}"
seed="${2:-5}"
if [[ ! "$seed" =~ ^[1-9][0-9]{0,8}$ ]] || (( $# > 2 )); then
	printf 'Usage: %s [Crowfield.app] [seed from 1 to 999999999]\n' "${0##*/}" >&2
	exit 2
fi
executable="$candidate/Contents/MacOS/Crowfield"
if [[ ! -x "$executable" ]]; then
	printf 'Place the exported Crowfield.app beside this launcher, or pass its path. Looked in %s\n' "$candidate" >&2
	exit 1
fi

runs="$HOME/Library/Application Support/Godot/app_userdata/Crowfield/playtests"
mkdir -p "$runs"
run_dir="$(mktemp -d "$runs/comparison-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'seed=%s\nbots=24\nmap=valley\n' "$seed" > "$run_dir/scenario.txt"
printf 'Run files are in %s\n' "$run_dir"
exec "$executable" --log-file "$run_dir/godot.log" -- client \
	-map=valley -bots=24 -solo-replay "-seed=$seed" "-dev-capture-dir=$run_dir" -name=Playtester -config-dir=
