# codex-antifreeze-shit-wrapper

A small PTY wrapper and terminal shim for `codex`.

The `codex-watch` script runs `codex` as an interactive terminal program, mirrors
your input/output normally, and watches the output for configured text. When the
text matches, it sends a configured reply followed by Enter. It can also send
the reply after an idle timeout.

The `codex` shim is the command you put earlier on your `PATH`. It replaces the
terminal entrypoint, finds the real `codex` binary, offers to attach to existing
tmux sessions, and launches new Codex sessions through `codex-watch`.

## Install

```sh
mkdir -p "$HOME/bin"
cp ./codex-watch "$HOME/bin/codex-watch"
cp ./codex "$HOME/bin/codex"
chmod +x "$HOME/bin/codex-watch"
chmod +x "$HOME/bin/codex"
```

Make sure `~/bin` is on your path before the real `codex` binary:

```sh
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Now this launches the shim:

```sh
codex
```

If tmux is installed and you are not already inside tmux, the shim lists running
tmux sessions first:

```text
Existing tmux sessions:
  1) codex-20260630-224500 (1 windows, detached)
  n) start new Codex tmux session
  r) run Codex here without tmux
  q) quit
Select tmux session [n]:
```

If there are no running tmux sessions, it starts a new tmux session and runs the
watched Codex command there. If tmux is unavailable or you are already inside
tmux, it runs the watched Codex command in the current terminal.

Arguments still pass through:

```sh
codex --some-codex-flag
```

## Configure

The simplest setup is to edit these two values at the top of `codex-watch`:

```python
TYPE_IN = "your unfreeze string here"
WHEN_OUTPUT_CONTAINS = "your exact matching text here"
```

`WHEN_OUTPUT_CONTAINS` is a plain substring match, not a regex. `TYPE_IN` is
typed into Codex and then Return is sent.

You can also override those defaults from `~/.zshrc`:

```sh
export CODEX_WATCH_MATCH='your exact matching text here'
export CODEX_WATCH_REPLY='your unfreeze string here'
export CODEX_WATCH_COOLDOWN=120
```

To send only Enter when the match text appears, leave the reply empty:

```sh
export CODEX_WATCH_REPLY=''
```

To also unfreeze after 30 minutes with no output:

```sh
export CODEX_WATCH_IDLE=1800
```

Use very specific match text; broad matches can accidentally answer prompts you
did not intend to answer.

## Bypass

Run watched Codex in the current terminal without tmux:

```sh
CODEX_TMUX=0 codex
```

Run the real Codex binary directly without the watcher:

```sh
CODEX_WATCH_DISABLE=1 CODEX_TMUX=0 codex
```

If the shim cannot find the real binary, set it explicitly:

```sh
CODEX_REAL_BIN=/opt/homebrew/bin/codex codex
```

Use a custom tmux session prefix:

```sh
CODEX_TMUX_SESSION_PREFIX=codex-work codex
```

## Use `codex-watch` Directly

Run `codex` through the watcher:

```sh
CODEX_WATCH_PATTERN='Press Enter|stalled|frozen|your exact matching text here' \
CODEX_WATCH_REPLY='your unfreeze string here' \
CODEX_WATCH_COOLDOWN=120 \
codex-watch -- codex
```

For a plain text match instead of a regex:

```sh
codex-watch --match 'your exact matching text here' --reply 'your unfreeze string here' -- codex
```

## Options

`codex-watch` supports these options:

```text
--pattern PATTERN      Regex to watch for. Defaults to CODEX_WATCH_PATTERN.
--match TEXT           Plain output text to watch for. Defaults to CODEX_WATCH_MATCH or WHEN_OUTPUT_CONTAINS.
--reply REPLY          Input to send when triggered. Defaults to CODEX_WATCH_REPLY or TYPE_IN.
--cooldown SECONDS     Minimum seconds between automatic replies.
--idle SECONDS         Also send the reply after this many seconds without output.
--buffer CHARS         Recent output characters kept for regex matching.
--no-strip-ansi        Match against raw terminal output including ANSI escapes.
```

The `codex` shim also reads these environment variables:

```text
CODEX_REAL_BIN              Real Codex binary path.
CODEX_WATCH_BIN             codex-watch path.
CODEX_WATCH_DISABLE=1       Run real Codex directly.
CODEX_WATCH_MATCH           Plain output text to watch for.
CODEX_TMUX=0                Do not use tmux.
CODEX_TMUX_INSIDE=1         Allow tmux selection even from inside tmux.
CODEX_TMUX_SESSION_NAME     Exact session name for a new tmux session.
CODEX_TMUX_SESSION_PREFIX   Prefix for generated tmux session names.
```
