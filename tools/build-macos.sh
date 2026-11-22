#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -sm) != 'Linux x86_64' ]]; then
    printf 'Run this build on an x86_64 Linux host.\n' >&2
    exit 1
fi

cd "$(dirname "$0")/.."
version=4.7.2
release="Godot_v$version-stable"
editor="${release}_linux.x86_64"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/crowfield/godot/$version"
templates="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$version.stable"
output="$PWD/export/macos"
mkdir -p "$cache" "$templates" "$output"
touch "$PWD/export/.gdignore"

# Serialize installs and builds that share this toolchain.
exec 9>"$cache/build.lock"
flock 9
stage=$(mktemp -d "$output/.build.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT

base_url="https://github.com/godotengine/godot-builds/releases/download/$version-stable"
fetch() {
    local asset=$1
    if [[ ! -s "$cache/$asset" ]]; then
        curl --fail --silent --show-error --location --retry 3 \
            --output "$cache/$asset.part" "$base_url/$asset"
        mv -- "$cache/$asset.part" "$cache/$asset"
    fi
}

verify() {
    local asset=$1
    (
        cd "$cache"
        awk -v asset="$asset" '$2 == asset { print }' SHA512-SUMS.txt |
            sha512sum --check --strict
    )
}

if [[ ! -x "$cache/$editor" ]]; then
    fetch SHA512-SUMS.txt
    fetch "$editor.zip"
    verify "$editor.zip"
    unzip -p "$cache/$editor.zip" "$editor" > "$stage/$editor"
    chmod +x "$stage/$editor"
    mv -- "$stage/$editor" "$cache/$editor"
fi

if [[ ! -s "$templates/macos.zip" ]]; then
    archive="${release}_export_templates.tpz"
    fetch SHA512-SUMS.txt
    fetch "$archive"
    verify "$archive"
    unzip -p "$cache/$archive" templates/macos.zip > "$stage/macos.zip"
    mv -- "$stage/macos.zip" "$templates/macos.zip"
fi

godot="$cache/$editor"
"$godot" --headless --path "$PWD" --import
"$godot" --headless --path "$PWD" --export-release macOS "$stage/Crowfield.zip"
# Add the checked-in credits alongside the already signed app.
mkdir -p "$stage/Credits/Barlow"
cp -- assets/audio/LICENSE.md "$stage/Credits/Audio.md"
cp -- assets/valley/LICENSE.md "$stage/Credits/Valley Textures.md"
cp -- assets/sky/LICENSE.md "$stage/Credits/Skies.md"
cp -- assets/desert/LICENSE.md "$stage/Credits/Desert.md"
cp -- assets/vehicles/LICENSE.md "$stage/Credits/Vehicles.md"
cp -- assets/type/SOURCE.md "$stage/Credits/Barlow/Source.md"
cp -- assets/type/OFL.txt "$stage/Credits/Barlow/OFL.txt"
(
    cd "$stage"
    zip -qr Crowfield.zip Credits
)

unzip -tq "$stage/Crowfield.zip"
mv -- "$stage/Crowfield.zip" "$output/Crowfield.zip"
printf 'Built %s\n' "$output/Crowfield.zip"
