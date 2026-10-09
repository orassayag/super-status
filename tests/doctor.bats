#!/usr/bin/env bats
# doctor.sh's settings.json patching, run against an isolated HOME.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    unset CLAUDE_CONFIG_DIR
    install_script "$HOME/.claude"
}

install_script() { # $1 = config folder
    mkdir -p "$1/super-status"
    cp "$REPO_ROOT/statusline.sh" "$1/super-status/statusline.sh"
}

@test "a symlinked settings.json stays a link and keeps its permissions" {
    target="$BATS_TEST_TMPDIR/dotfiles/settings.json"
    mkdir -p "$(dirname "$target")"
    echo '{"theme":"dark"}' > "$target"
    chmod 644 "$target"
    ln -s "$target" "$HOME/.claude/settings.json"

    run bash "$REPO_ROOT/doctor.sh"
    [ "$status" -eq 0 ]
    [ -L "$HOME/.claude/settings.json" ]
    perms=$(stat -f %Lp "$target" 2>/dev/null || stat -c %a "$target")
    [ "$perms" = "644" ]
    [ "$(jq -r '.statusLine.command' "$target")" = "/bin/bash $HOME/.claude/super-status/statusline.sh" ]
    [ "$(jq -r '.theme' "$target")" = "dark" ]
}

@test "doctor wires the settings.json inside CLAUDE_CONFIG_DIR" {
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/relocated"
    install_script "$CLAUDE_CONFIG_DIR"

    run bash "$REPO_ROOT/doctor.sh"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.statusLine.command' "$CLAUDE_CONFIG_DIR/settings.json")" = "/bin/bash $CLAUDE_CONFIG_DIR/super-status/statusline.sh" ]
    [ ! -f "$HOME/.claude/settings.json" ]
}
