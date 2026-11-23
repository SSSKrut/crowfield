# Linux development and standalone builds

Run commands from the remote issue worktree. The project pins Godot 4.7.2 in `tools/build-macos.sh`.

```sh
godot="$HOME/.cache/crowfield/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64"
"$godot" --headless --path . --import
"$godot" --headless --path . -- test
"$godot" --headless --path . -- test movement
"$godot" --path . -- client -map=valley -bots=24 -stats=1s
"$godot" --headless --path . -- loadtest -clients=4 -bots=24 -duration=30s
```

Run `./tools/build-macos.sh` from the exact Linux revision being exported. The script installs the pinned editor and export template on demand and writes `export/macos/Crowfield.zip` with the app and credits. Use the export presets for Linux, Windows, and dedicated Linux server builds. For a main build, use a clean worktree at the fetched `origin/main`.

Transfer the ZIP from the same worktree. Verify its digest, extract with `ditto -x -k`, and run `codesign --verify --deep --strict Crowfield.app`. Keep the app and credits together. Stage a preview separately from any build the user may have in use. Get approval before starting a foreground Mac diagnostic. A headless smoke check can verify that the prebuilt app joins and advances a solo match.

Use `client -help`, `server -help`, or `loadtest -help` after `--` for the current flags. The `-movement`, `-shoot`, and `-demo` scenarios run on the prototype map by default. For a bounded movement screenshot, pass `-movement -max-fps=60 -frames=400 -screenshot=movement.png`.

## Multiplayer

Choose **Multiplayer → Host game**. Escape shows the address and certificate fingerprint. On another client, enter the address and choose **Join**. Same-machine clients can use `127.0.0.1`. The default port is UDP 7777.

```sh
"$godot" --headless --path . -- server -listen :7777 -map=valley -bots=24
"$godot" --path . -- client -connect 127.0.0.1:7777
```

Validate a changed server certificate with the host before passing `-fingerprint`. Use matching builds and matching `-tuning` and `-weapons` rules across clients and server.
