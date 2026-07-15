# codex-antifreeze-wrapper

A small wrapper that keeps Codex moving in long-running tmux sessions.

It runs Codex through a PTY watcher and automatically:

- Sends `/goal resume` when `Goal blocked` appears.
- Uses arrow keys to select **Keep waiting**, then presses Return when the
  complete **Additional safety checks** prompt appears.
- Keeps working after you detach from tmux.

The two automatic actions are independent and protected by separate cooldowns.
Safety prompts detected during their cooldown are left untouched; the watcher
does not queue arrow keys or Return for later, when the prompt may be gone.

## Install

The real Codex CLI must already be installed. Then run:

```sh
/bin/bash -c 'set -e; if ! command -v curl >/dev/null; then if command -v apt-get >/dev/null; then if [ "$(id -u)" -eq 0 ]; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates; else sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates; fi; else echo "curl is required" >&2; exit 1; fi; fi; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fsSL https://raw.githubusercontent.com/wktkow/codex-antifreeze-wrapper/main/install.sh -o "$f"; /bin/bash "$f"'
```

The installer supports Ubuntu-based Linux and macOS. It installs the wrapper in
`~/.local/bin`, installs missing Python/tmux dependencies with apt or Homebrew,
detects Bash, Zsh, and Fish configs, and asks before overriding the interactive
`codex` command with a shell-compatible alias. It also explains and offers to
append the required `Ctrl-M` keymap to `~/.codex/config.toml`. It is safe to
rerun: each run downloads and replaces both managed executables, updating any
preexisting wrapper install in the selected install directory. It refuses to
overwrite unrelated executables or non-file destinations in its install path.
Reruns do not repeat optional keymap or alias questions: existing
installer-managed pieces are refreshed automatically, while absent optional
pieces are left unchanged. Equivalent manual keymap and alias settings are
detected and left untouched. Missing required dependencies may still require
confirmation.

Codex must treat `Ctrl-M` as submit. Add this to `~/.codex/config.toml`:

```toml
[tui.keymap.composer]
submit = ["enter", "ctrl-m"]

[tui.keymap.editor]
insert_newline = ["ctrl-j", "shift-enter", "alt-enter"]
```

Then launch normally:

```sh
codex
```

## tmux behavior

A no-argument launch creates a session named after the current directory, for
example `codex-my-project`. If it already exists, you get:

```text
Codex tmux session 'codex-my-project' is already running.
Attach to it or create a new one? [A/n/q]
```

- Enter or `a`: attach.
- `n`: create `codex-my-project-2`, then `-3`, and so on.
- `q`: quit.
- `Ctrl-B`, then `d`: detach. Codex and both watchers keep running.

Inside tmux, Codex runs in the current session without nesting another tmux.
Commands with arguments start in a dedicated project tmux session. There is
intentionally no mode that runs Codex outside tmux.

## Configuration

Defaults are at the top of `codex-watch`. The important ones are:

```python
TYPE_IN = "/goal resume"
WHEN_OUTPUT_CONTAINS = "Goal blocked"
SUBMIT_KEY = "ctrl-m"
MIN_SECONDS_BETWEEN_UNFREEZES = 4
SAFETY_CHECK_COOLDOWN_SECONDS = 4
```

Environment variables override the defaults:

```sh
export CODEX_WATCH_MATCH='Goal blocked'
export CODEX_WATCH_REPLY='/goal resume'
export CODEX_WATCH_SUBMIT_KEY=ctrl-m
export CODEX_WATCH_COOLDOWN=4
export CODEX_WATCH_SAFETY_CHECK_COOLDOWN=4
# Optional diagnostics go to a file, never into the live Codex screen.
export CODEX_WATCH_LOG=/tmp/codex-watch.log
```

For the additional-safety-checks menu, the watcher sends only one arrow at a
time. It waits for a later terminal redraw that visibly marks `Keep waiting` as
active before sending Return. Each displayed menu is handled at most once; if
the selection cannot be confirmed, it leaves the menu for manual input.

Normal output matches are also handled once per displayed tmux-screen episode.
The watcher rearms only after the matched text has disappeared from the pane,
so a frozen or fragmented redraw cannot repeatedly inject the configured reply.

Useful switches:

```sh
# Disable the watcher while still running Codex inside tmux.
CODEX_WATCH_DISABLE=1 codex

# Disable only the automatic safety-check Return.
CODEX_WATCH_NO_SAFETY_CHECK_RETURN=1 codex

# Override the project directory or session name.
CODEX_TMUX_DIR=/path/to/project codex
CODEX_TMUX_SESSION=codex-work codex

# Point the shim at Codex explicitly if auto-detection fails.
CODEX_REAL_BIN=/path/to/real/codex codex
```

For every watcher option:

```sh
codex-watch --help
```

Use specific match text. Broad matches can submit input at the wrong prompt.
