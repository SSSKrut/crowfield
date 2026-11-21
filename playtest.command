#!/bin/bash
# Record a local Mac playtest and stop the game if it freezes.
set -u

project_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)" || exit 1
godot="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
if [[ ! -x "$godot" ]]; then
	printf 'Godot executable not found at %s\nInstall Godot in Applications or set GODOT_BIN.\n' "$godot" >&2
	exit 1
fi

playtests_dir="$HOME/Library/Application Support/Godot/app_userdata/Crowfield/playtests"
mkdir -p -- "$playtests_dir" || exit 1
started="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$(mktemp -d "$playtests_dir/run-$started-XXXXXX")" || exit 1
log_path="$run_dir/godot.log"
recorder_log="$run_dir/recorder.log"
: > "$log_path" || exit 1
ln -sfn "${run_dir##*/}" "$playtests_dir/latest"
{
	printf 'started_utc=%s\n' "$started"
	if revision="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)"; then
		printf 'revision=%s\n' "$revision"
		if changes="$(git -C "$project_dir" status --porcelain 2>/dev/null)"; then
			tree=clean
			[[ -z "$changes" ]] || tree=dirty
			printf 'working_tree=%s\n' "$tree"
		fi
	fi
} > "$run_dir/run.txt"
printf 'Playtest files %s\n' "$run_dir"

game_pid=""
recorder_pid=""
setup_pid=""
stop_process() {
	local pid="$1" deadline=$((SECONDS + $2))
	[[ -n "$pid" ]] || return 0
	while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
		sleep 1
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -KILL "$pid" 2>/dev/null || true
	fi
	wait "$pid" 2>/dev/null || true
}

cleanup() {
	trap '' HUP INT TERM
	if [[ -n "$game_pid" ]]; then
		kill -TERM "$game_pid" 2>/dev/null || true
	fi
	if [[ -n "$recorder_pid" ]]; then
		kill -TERM "$recorder_pid" 2>/dev/null || true
	fi
	if [[ -n "$setup_pid" ]]; then
		kill -TERM "$setup_pid" 2>/dev/null || true
	fi
	stop_process "$game_pid" 5
	[[ ! -f "$run_dir/.gameplay-captured-pid" ]] || /bin/rm "$run_dir/.gameplay-captured-pid"
	stop_process "$recorder_pid" 8
	stop_process "$setup_pid" 5
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep at least one GiB free for the OS and trace. Gameplay still gets logged
# when video is unavailable or stopped.
video_space_available() {
	local available
	available="$(df -Pk "$run_dir" 2>/dev/null | awk 'NR == 2 {print $4}')"
	[[ "$available" =~ ^[0-9]+$ ]] && (( available >= 1048576 ))
}

video_unavailable() {
	printf '%s\n' "$1" >> "$recorder_log"
	printf '%s See %s\n' "$1" "$recorder_log" >&2
}

recorder_src="$project_dir/tools/playtest-recorder.swift"
recorder="$playtests_dir/.playtest-recorder"
prepare_recorder() {
	if ! video_space_available; then
		video_unavailable 'Video needs at least 1 GiB of free disk space.'
		return 1
	fi
	if [[ ! -f "$recorder_src" ]]; then
		video_unavailable 'The playtest recorder source is missing.'
		return 1
	fi
	if [[ -x "$recorder" && ! "$recorder_src" -nt "$recorder" ]]; then
		return 0
	fi
	if ! xcode-select -p >> "$recorder_log" 2>&1 || ! xcrun --find swiftc >> "$recorder_log" 2>&1; then
		video_unavailable 'Video needs the macOS Command Line Tools.'
		return 1
	fi
	# Build alongside the session. Rename only a complete binary into the
	# stable cache path so simultaneous launches cannot pick up a partial file.
	local built="$run_dir/playtest-recorder" status
	xcrun swiftc -parse-as-library -O "$recorder_src" -o "$built" >> "$recorder_log" 2>&1 &
	setup_pid=$!
	wait "$setup_pid"
	status=$?
	setup_pid=""
	if (( status != 0 )) || ! mv -f "$built" "$recorder"; then
		video_unavailable 'The playtest recorder did not compile.'
		return 1
	fi
}

if [[ ! -f "$project_dir/.godot/global_script_class_cache.cfg" || ! -d "$project_dir/.godot/imported" ]]; then
	printf 'First run, importing project assets.\n'
	"$godot" --headless --path "$project_dir" --log-file "$run_dir/import.log" --import &
	setup_pid=$!
	wait "$setup_pid"
	status=$?
	setup_pid=""
	if (( status != 0 )); then
		printf 'Godot import failed. See %s\n' "$run_dir/import.log" >&2
		exit "$status"
	fi
fi

record_video=false
if prepare_recorder; then
	record_video=true
fi
native_input_enabled=false
if [[ "$(uname -s)" == Darwin ]]; then
	native_build_log="$run_dir/native-input-build.log"
	bash "$project_dir/tools/build-native-input.sh" "$godot" "$project_dir/.godot/playtest-native" > "$native_build_log" 2>&1 &
	setup_pid=$!
	if wait "$setup_pid"; then
		native_input_enabled=true
	else
		printf 'Native input timing unavailable. See %s\n' "$native_build_log" >&2
	fi
	setup_pid=""
fi
"$godot" --path "$project_dir" --windowed --log-file "$log_path" -- client \
	-width=1280 -height=720 -map=valley -bots=24 -max-fps=60 -stats=5s -exit-on-leave \
	"-dev-capture-dir=$run_dir" "-dev-native-input=$native_input_enabled" &
game_pid=$!
if $record_video; then
	"$recorder" --pid "$game_pid" --output "$run_dir/gameplay.mp4" >> "$recorder_log" 2>&1 &
	recorder_pid=$!
fi

last_heartbeat=0
last_progress=$SECONDS
heartbeat_timeout=90
while kill -0 "$game_pid" 2>/dev/null; do
	sleep 2
	if [[ -n "$recorder_pid" ]]; then
		if ! kill -0 "$recorder_pid" 2>/dev/null; then
			if ! wait "$recorder_pid"; then
				printf 'Video recording ended. See %s\n' "$recorder_log" >&2
			fi
			recorder_pid=""
		fi
	fi
	if read -r heartbeats fence_timeouts < <(awk '
		/^client: fps=/ { heartbeats++ }
		tolower($0) ~ /timeout waiting for fence/ { fence_timeouts++ }
		END { print heartbeats + 0, fence_timeouts + 0 }
	' "$log_path" 2>/dev/null) && (( heartbeats > last_heartbeat )); then
		last_heartbeat=$heartbeats
		last_progress=$SECONDS
		heartbeat_timeout=35
	fi
	reason=""
	if (( ${fence_timeouts:-0} >= 3 )); then
		reason="repeated GPU fence timeouts"
	elif (( SECONDS - last_progress >= heartbeat_timeout )); then
		reason="no frame heartbeat for $heartbeat_timeout seconds"
	fi
	if [[ -n "$reason" ]] && kill -0 "$game_pid" 2>/dev/null; then
		printf 'Playtest stopped after %s.\n' "$reason" >&2
		printf '\nPlaytest watchdog stopped Godot after %s.\n' "$reason" >> "$log_path"
		exit 1
	fi
done

wait "$game_pid"
status=$?
game_pid=""
exit "$status"
