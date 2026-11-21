#!/bin/bash
# Build the optional local AppKit event monitor using the running engine's ABI.
set -eu

godot="$1"
build_dir="$2"
source_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source="$source_dir/playtest-native-input.mm"
library="$build_dir/native-input.dylib"
descriptor="$build_dir/native-input.gdextension"

if [[ -s "$library" && -s "$descriptor" && ! "$godot" -nt "$library" && ! "$source" -nt "$library" && ! "$0" -nt "$library" ]]; then
	exit 0
fi

mkdir -p -- "$build_dir"
stage="$(mktemp -d "$build_dir/stage-XXXXXX")"
trap 'rm -f -- "$stage/gdextension_interface.h" "$stage/native-input.dylib" "$stage/native-input.gdextension" "$stage/interface.log"; rmdir -- "$stage"' EXIT
(
	cd -- "$stage"
	"$godot" --headless --log-file "$stage/interface.log" --dump-gdextension-interface
)
xcrun clang++ -arch "$(uname -m)" -fobjc-arc -O2 -Wall -Wextra -Werror -dynamiclib 	-framework AppKit -I "$stage" "$source" -o "$stage/native-input.dylib"
cat > "$stage/native-input.gdextension" <<'DESCRIPTOR'
[configuration]
entry_symbol = "crowfield_native_input_init"
compatibility_minimum = "4.7"

[libraries]
macos = "res://.godot/playtest-native/native-input.dylib"
DESCRIPTOR
mv -f -- "$stage/native-input.dylib" "$library"
mv -f -- "$stage/native-input.gdextension" "$descriptor"
