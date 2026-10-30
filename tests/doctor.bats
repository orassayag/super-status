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
    # Git Bash without developer mode makes `ln -s` copy the file instead.
    [ -L "$HOME/.claude/settings.json" ] || skip "ln -s cannot create symlinks here"

    run bash "$REPO_ROOT/doctor.sh"
    [ "$status" -eq 0 ]
    [ -L "$HOME/.claude/settings.json" ]
    # GNU first: GNU `stat -f` means filesystem status and succeeds with junk.
    perms=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")
    [ "$perms" = "644" ]
    [ "$(jq -r '.statusLine.command' "$target")" = "/bin/bash $HOME/.claude/super-status/statusline.sh" ]
    [ "$(jq -r '.theme' "$target")" = "dark" ]
}

@test "doctor wires the settings.json inside CLAUDE_CONFIG_DIR" {
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/relocated"
    install_script "$CLAUDE_CONFIG_DIR"

    run bash "$REPO_ROOT/doctor.sh"
    [ "$status" -eq 0 ]
    echo "doctor output: $output"
    [ "$(jq -r '.statusLine.command' "$CLAUDE_CONFIG_DIR/settings.json" | tr -d '\r')" = "/bin/bash $CLAUDE_CONFIG_DIR/super-status/statusline.sh" ]
    [ ! -f "$HOME/.claude/settings.json" ]
}

@test "doctor defaults refreshInterval to 30s on Git Bash and keeps an existing one" {
    echo '{}' > "$HOME/.claude/settings.json"
    OSTYPE=msys run bash -c 'export OSTYPE=msys; bash "$0"' "$REPO_ROOT/doctor.sh"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.statusLine.refreshInterval' "$HOME/.claude/settings.json" | tr -d '\r')" = "30" ]

    echo '{"statusLine":{"refreshInterval":5}}' > "$HOME/.claude/settings.json"
    run bash "$REPO_ROOT/doctor.sh"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.statusLine.refreshInterval' "$HOME/.claude/settings.json" | tr -d '\r')" = "5" ]
}
