#!/bin/bash
set -euo pipefail

launcher_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
game="$launcher_dir/Crowfield.app/Contents/MacOS/Crowfield"
if [[ ! -x "$game" ]]; then
    printf 'Keep this launcher beside the extracted Crowfield.app.\n' >&2
    exit 1
fi

exec "$game" --fullscreen --rendering-method mobile --rendering-driver metal "$@"
