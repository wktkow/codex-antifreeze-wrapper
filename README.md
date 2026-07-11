# codex-antifreeze-shit-wrapper

A small wrapper that keeps Codex moving in long-running tmux sessions.

It runs Codex through a PTY watcher and automatically:

- Sends `/goal resume` when `Goal blocked` appears.
- Presses Return when the complete **Additional safety checks / Keep waiting**
  prompt appears.
- Keeps working after you detach from tmux.

The two automatic actions are independent and protected by separate cooldowns.

## Install

Requirements: Codex and Python 3. tmux is optional but recommended.

```sh
git clone https://github.com/wktkow/codex-antibug-shit-wrapper.git
cd codex-antibug-shit-wrapper
mkdir -p "$HOME/bin"
install -m 755 codex codex-watch "$HOME/bin/"
```

Recommended: alias `codex` to the wrapper in your shell config.

```sh
# Bash
echo 'alias codex="$HOME/bin/codex"' >> ~/.bashrc
source ~/.bashrc

# Zsh
echo 'alias codex="$HOME/bin/codex"' >> ~/.zshrc
source ~/.zshrc
```

Use only the pair for your shell. Alternatively, put `~/bin` before the real
Codex binary on your `PATH` with `export PATH="$HOME/bin:$PATH"`.

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

Inside tmux, or when passing Codex arguments, the session prompt is skipped.
If tmux is not installed, watched Codex runs directly in the current terminal.

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
```

Useful switches:

```sh
# Run watched Codex without tmux.
CODEX_NO_TMUX=1 codex

# Run the real Codex binary without tmux or the watcher.
CODEX_NO_TMUX=1 CODEX_WATCH_DISABLE=1 codex

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
