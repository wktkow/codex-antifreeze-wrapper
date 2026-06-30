# codex-antifreeze-shit-wrapper

A small PTY wrapper and terminal shim for `codex`.

The `codex-watch` script runs `codex` as an interactive terminal program, mirrors
your input/output normally, and watches the output for configured text. When the
text matches, it sends a configured reply followed by a submit key. It can also
send the reply after an idle timeout.

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
watched Codex command there. If you are already inside tmux, it runs the watched
Codex command in the current terminal.

For interactive terminals, tmux is expected by default. If tmux cannot be found,
the shim exits with an error instead of silently running Codex outside tmux. Use
`CODEX_TMUX=0 codex` when you intentionally want to run without tmux.

Arguments still pass through:

```sh
codex --some-codex-flag
```

## Configure

The simplest setup is to edit these values at the top of `codex-watch`:

```python
TYPE_IN = "your unfreeze string here"
WHEN_OUTPUT_CONTAINS = "your exact matching text here"
SUBMIT_KEY = "ctrl-x"
MIN_SECONDS_BETWEEN_UNFREEZES = 60
MAX_UNFREEZES_PER_WINDOW = 3
UNFREEZE_WINDOW_SECONDS = 600
```

`WHEN_OUTPUT_CONTAINS` is a plain substring match, not a regex. `TYPE_IN` is
typed into Codex and then `SUBMIT_KEY` is sent. The default is `ctrl-x` because
plain Return can be configured as newline in Codex, and Ctrl-Enter depends on
terminal escape-sequence support.

Make sure Codex has `ctrl-x` bound as a submit key:

```toml
[tui.keymap.composer]
submit = ["enter", "ctrl-x"]
```

After firing, the watcher latches the match so the same emitted text does not
cause a tight reply loop. If the match stays visible, it retries after the
cooldown instead of waiting forever for the text to disappear. It rearms early
when later output no longer contains the match text.

It also treats frequent repeated unfreezes as a bug. By default it will send at
most 3 automatic replies in 10 minutes, and it will never send replies less than
60 seconds apart. Suppressed replies are printed as `codex-watch` status
messages instead of being sent to Codex.

Inside tmux, `Ctrl-b` then `d` detaches the session. Normally tmux handles that
before the keypress reaches `codex-watch`; if it does reach the watcher, the
watcher now treats it as a fallback detach hotkey and runs `tmux detach-client`.
Set `CODEX_WATCH_NO_TMUX_DETACH_HOTKEY=1` to disable that fallback.

You can also override those defaults from `~/.zshrc`:

```sh
export CODEX_WATCH_MATCH='your exact matching text here'
export CODEX_WATCH_REPLY='your unfreeze string here'
export CODEX_WATCH_SUBMIT_KEY=ctrl-x
export CODEX_WATCH_COOLDOWN=60
export CODEX_WATCH_MAX_UNFREEZES=3
export CODEX_WATCH_WINDOW=600
```

To send only the submit key when the match text appears, leave the reply empty:

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

Use a specific tmux binary if it is installed outside `PATH`:

```sh
CODEX_TMUX_BIN=/opt/homebrew/bin/tmux codex
```

## Use `codex-watch` Directly

Run `codex` through the watcher:

```sh
CODEX_WATCH_PATTERN='Press Enter|stalled|frozen|your exact matching text here' \
CODEX_WATCH_REPLY='your unfreeze string here' \
CODEX_WATCH_SUBMIT_KEY=ctrl-x \
CODEX_WATCH_COOLDOWN=60 \
codex-watch -- codex
```

For a plain text match instead of a regex:

```sh
codex-watch --match 'your exact matching text here' --reply 'your unfreeze string here' --submit-key ctrl-x -- codex
```

## Options

`codex-watch` supports these options:

```text
--pattern PATTERN      Regex to watch for. Defaults to CODEX_WATCH_PATTERN.
--match TEXT           Plain output text to watch for. Defaults to CODEX_WATCH_MATCH or WHEN_OUTPUT_CONTAINS.
--reply REPLY          Input to send when triggered. Defaults to CODEX_WATCH_REPLY or TYPE_IN.
--submit-key KEY       Key sequence sent after --reply. Defaults to CODEX_WATCH_SUBMIT_KEY or SUBMIT_KEY.
--cooldown SECONDS     Minimum seconds between automatic replies.
--max-unfreezes COUNT  Maximum automatic replies allowed within --window. Use 0 to disable.
--window SECONDS       Seconds used for the repeated-unfreeze circuit breaker.
--idle SECONDS         Also send the reply after this many seconds without output.
--buffer CHARS         Recent output characters kept for regex matching.
--no-strip-ansi        Match against raw terminal output including ANSI escapes.
--no-tmux-detach-hotkey
                       Do not intercept Ctrl-b then d as tmux detach inside tmux.
```

The `codex` shim also reads these environment variables:

```text
CODEX_REAL_BIN              Real Codex binary path.
CODEX_WATCH_BIN             codex-watch path.
CODEX_WATCH_DISABLE=1       Run real Codex directly.
CODEX_WATCH_MATCH           Plain output text to watch for.
CODEX_WATCH_REPLY           Input to send when triggered.
CODEX_WATCH_SUBMIT_KEY      Key sequence sent after CODEX_WATCH_REPLY.
CODEX_WATCH_COOLDOWN        Minimum seconds between automatic replies.
CODEX_WATCH_MAX_UNFREEZES   Maximum automatic replies allowed per window.
CODEX_WATCH_WINDOW          Circuit breaker window in seconds.
CODEX_WATCH_NO_TMUX_DETACH_HOTKEY
                              Disable the Ctrl-b then d fallback detach hotkey.
CODEX_TMUX=0                Do not use tmux.
CODEX_TMUX_BIN              tmux binary path.
CODEX_TMUX_INSIDE=1         Allow tmux selection even from inside tmux.
CODEX_TMUX_SESSION_NAME     Exact session name for a new tmux session.
CODEX_TMUX_SESSION_PREFIX   Prefix for generated tmux session names.
```
