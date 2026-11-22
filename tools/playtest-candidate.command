#!/usr/bin/env bash
# Start a comparative Valley round using a standalone macOS or Linux export.
set -euo pipefail

launcher_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
case "$(uname -s)" in
	Darwin)
		default_candidate="$launcher_dir/Crowfield.app"
		runs="$HOME/Library/Application Support/Godot/app_userdata/Crowfield/playtests"
		;;
	Linux)
		default_candidate="$launcher_dir/crowfield.x86_64"
		runs="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Crowfield/playtests"
		;;
	*)
		printf 'This launcher supports macOS and Linux.\n' >&2
		exit 1
		;;
esac
candidate="${1:-$default_candidate}"
seed="${2:-5}"
if [[ ! "$seed" =~ ^[1-9][0-9]{0,8}$ ]] || (( $# > 2 )); then
	printf 'Usage: %s [game path] [seed from 1 to 999999999]\n' "${0##*/}" >&2
	exit 2
fi
executable="$candidate"
if [[ -d "$candidate" ]]; then
	executable="$candidate/Contents/MacOS/Crowfield"
fi
if [[ ! -f "$executable" || ! -x "$executable" ]]; then
	printf 'Extract the game beside this launcher, or pass its path. Looked in %s\n' "$candidate" >&2
	exit 1
fi
mkdir -p "$runs"
run_dir="$(mktemp -d "$runs/comparison-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'seed=%s\nbots=24\nmap=valley\n' "$seed" > "$run_dir/scenario.txt"
printf 'Run files are in %s\n' "$run_dir"
exec "$executable" --rendering-method gl_compatibility --log-file "$run_dir/godot.log" -- client \
	-map=valley -bots=24 -solo-replay "-seed=$seed" "-dev-capture-dir=$run_dir" -name=Playtester -config-dir=
