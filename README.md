# codex-antifreeze-shit-wrapper

A small PTY wrapper and terminal shim for `codex`.

The `codex-watch` script runs `codex` as an interactive terminal program, mirrors
your input/output normally, and watches the output for configured text. When the
text matches, it sends a configured reply followed by a submit key. It can also
send the reply after an idle timeout.

In parallel with that configurable match/reply mode, the watcher recognizes the
complete additional-safety-checks prompt. If all three prompt strings are
present in recent terminal output, it sends a bare Return key to select **Keep
waiting**. This does not type the normal configured reply.

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

On Pop!_OS, Ubuntu, and other systems using Bash by default, use `~/.bashrc`
instead:

```sh
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

On Linux, the shim checks for the dependencies needed by the current invocation.
If `python3` or `tmux` is missing on an apt-based system, an interactive run
offers to install the missing packages with `sudo apt-get`. `sudo` handles the
password prompt directly. Package configuration uses Debian's non-interactive
frontend so the install cannot stall on an additional configuration question.
The default answer is no, and non-interactive runs never install packages
automatically; they print the command to run instead.

The tmux check is skipped when tmux will not be used, such as with
`CODEX_TMUX=0 codex`. The Python check is skipped when the watcher is disabled
with `CODEX_WATCH_DISABLE=1`. To disable the Linux dependency check entirely,
set `CODEX_LINUX_DEP_CHECK=0`.

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
SUBMIT_KEY = "ctrl-m"
USE_BRACKETED_PASTE = True
TYPE_KEY_DELAY_SECONDS = 0.015
SUBMIT_DELAY_SECONDS = 0.15
MIN_SECONDS_BETWEEN_UNFREEZES = 15
MAX_UNFREEZES_PER_WINDOW = 0
UNFREEZE_WINDOW_SECONDS = 600
```

`WHEN_OUTPUT_CONTAINS` is a plain substring match, not a regex. `TYPE_IN` is
typed into Codex and then `SUBMIT_KEY` is sent. The default is `ctrl-m` because
the wrapper sends a raw carriage-return byte; Codex must bind that byte to
submit instead of treating it as an editor newline.

By default, the reply is inserted with terminal bracketed paste so slash
commands with arguments, such as `/goal resume`, arrive in Codex as one complete
composer update. `SUBMIT_DELAY_SECONDS` then gives Codex time to process that
paste before the submit key is sent.

Make sure Codex has `ctrl-m` bound as a submit key and removed from editor
newline bindings:

```toml
[tui.keymap.composer]
submit = ["enter", "ctrl-m"]

[tui.keymap.editor]
insert_newline = ["ctrl-j", "shift-enter", "alt-enter"]
```

After firing, the watcher latches the match so the same emitted text does not
cause a tight reply loop. If the match stays visible, it retries after the
cooldown instead of waiting forever for the text to disappear. It rearms early
when later output no longer contains the match text.

By default it will never send replies less than 15 seconds apart. The repeated
unfreeze circuit breaker is disabled with `MAX_UNFREEZES_PER_WINDOW = 0`.
Suppressed cooldown replies are printed as `codex-watch` status messages instead
of being sent to Codex.

Inside tmux, `Ctrl-b` then `d` detaches the session. Normally tmux handles that
before the keypress reaches `codex-watch`; if it does reach the watcher, the
watcher now treats it as a fallback detach hotkey and runs `tmux detach-client`.
Set `CODEX_WATCH_NO_TMUX_DETACH_HOTKEY=1` to disable that fallback.

You can also override those defaults from `~/.zshrc`:

```sh
export CODEX_WATCH_MATCH='your exact matching text here'
export CODEX_WATCH_REPLY='your unfreeze string here'
export CODEX_WATCH_SUBMIT_KEY=ctrl-m
export CODEX_WATCH_NO_BRACKETED_PASTE=0
export CODEX_WATCH_TYPE_DELAY=0.015
export CODEX_WATCH_SUBMIT_DELAY=0.15
export CODEX_WATCH_COOLDOWN=15
export CODEX_WATCH_MAX_UNFREEZES=0
export CODEX_WATCH_WINDOW=600
export CODEX_WATCH_NO_SAFETY_CHECK_RETURN=0
export CODEX_WATCH_SAFETY_CHECK_COOLDOWN=4
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

The safety-check Return mode is enabled by default and requires all of these
exact strings before it fires:

```text
Additional safety checks
This request requires additional safety checks, which can take extra time.
Keep waiting
```

It has a separate cooldown from normal automatic replies, so both modes remain
active independently. Set `CODEX_WATCH_NO_SAFETY_CHECK_RETURN=1` (or pass
`--no-safety-check-return`) to disable it.

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
CODEX_WATCH_SUBMIT_KEY=ctrl-m \
CODEX_WATCH_NO_BRACKETED_PASTE=0 \
CODEX_WATCH_TYPE_DELAY=0.015 \
CODEX_WATCH_SUBMIT_DELAY=0.15 \
CODEX_WATCH_COOLDOWN=15 \
codex-watch -- codex
```

For a plain text match instead of a regex:

```sh
codex-watch --match 'your exact matching text here' --reply 'your unfreeze string here' --submit-key ctrl-m -- codex
```

## Options

`codex-watch` supports these options:

```text
--pattern PATTERN      Regex to watch for. Defaults to CODEX_WATCH_PATTERN.
--match TEXT           Plain output text to watch for. Defaults to CODEX_WATCH_MATCH or WHEN_OUTPUT_CONTAINS.
--reply REPLY          Input to send when triggered. Defaults to CODEX_WATCH_REPLY or TYPE_IN.
--submit-key KEY       Key sequence sent after --reply. Defaults to CODEX_WATCH_SUBMIT_KEY or SUBMIT_KEY.
--no-bracketed-paste   Type --reply as key bytes instead of using terminal bracketed paste.
--type-delay SECONDS   Seconds to wait between bytes of --reply.
--submit-delay SECONDS
                       Seconds to wait between --reply and --submit-key.
--cooldown SECONDS     Minimum seconds between automatic replies.
--max-unfreezes COUNT  Maximum automatic replies allowed within --window. Use 0 to disable.
--window SECONDS       Seconds used for the repeated-unfreeze circuit breaker when --max-unfreezes is above 0.
--idle SECONDS         Also send the reply after this many seconds without output.
--no-safety-check-return
                       Do not press Return for the complete additional-safety-checks prompt.
--safety-check-cooldown SECONDS
                       Minimum seconds between safety-check Return keypresses.
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
CODEX_WATCH_NO_BRACKETED_PASTE
                              Type CODEX_WATCH_REPLY as key bytes instead of bracketed paste.
CODEX_WATCH_TYPE_DELAY      Seconds to wait between bytes of CODEX_WATCH_REPLY.
CODEX_WATCH_SUBMIT_DELAY    Seconds to wait before CODEX_WATCH_SUBMIT_KEY.
CODEX_WATCH_COOLDOWN        Minimum seconds between automatic replies.
CODEX_WATCH_MAX_UNFREEZES   Maximum automatic replies allowed per window. Use 0 to disable.
CODEX_WATCH_WINDOW          Circuit breaker window in seconds.
CODEX_WATCH_NO_SAFETY_CHECK_RETURN
                              Disable automatic Return for the complete safety-check prompt.
CODEX_WATCH_SAFETY_CHECK_COOLDOWN
                              Minimum seconds between safety-check Return keypresses.
CODEX_WATCH_NO_TMUX_DETACH_HOTKEY
                              Disable the Ctrl-b then d fallback detach hotkey.
CODEX_TMUX=0                Do not use tmux.
CODEX_TMUX_BIN              tmux binary path.
CODEX_TMUX_INSIDE=1         Allow tmux selection even from inside tmux.
CODEX_TMUX_SESSION_NAME     Exact session name for a new tmux session.
CODEX_TMUX_SESSION_PREFIX   Prefix for generated tmux session names.
CODEX_LINUX_DEP_CHECK=0     Disable the Linux dependency check and install prompt.
```
