import importlib.machinery
import importlib.util
import json
import os
import pathlib
import pty
import shlex
import shutil
import signal
import subprocess
import sys
import termios
import time
import unittest
import uuid


MODULE_PATH = pathlib.Path(__file__).with_name("codex-watch")
LOADER = importlib.machinery.SourceFileLoader("codex_watch", str(MODULE_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
codex_watch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(codex_watch)


def option_selected_at_return(active_index, option_count, keys):
    for key in keys:
        if key == codex_watch.ARROW_UP_SEQUENCE:
            active_index = option_count if active_index == 1 else active_index - 1
        elif key == codex_watch.ARROW_DOWN_SEQUENCE:
            active_index = 1 if active_index == option_count else active_index + 1
        elif key == codex_watch.RETURN_SEQUENCE:
            return active_index
    return None


FAKE_CODEX_MENU = r"""
import json
import os
import sys
import time
import tty

labels = json.loads(sys.argv[1])
active = int(sys.argv[2])
fragmented = sys.argv[3] == "fragmented"
tty.setraw(0)

def render():
    lines = [
        "Additional safety checks",
        "This request requires additional safety checks, which can take extra time.",
    ]
    for option_index, label in enumerate(labels, 1):
        marker = "›" if option_index == active else " "
        if fragmented and option_index == active:
            marker = "\x1b[1m›\x1b[0m"
        lines.append(f"{marker} {option_index}. {label}")
    prompt = ("\n".join(lines) + "\n").encode()

    if fragmented:
        for byte in prompt:
            os.write(1, bytes([byte]))
            time.sleep(0.0005)
    else:
        os.write(1, prompt)

render()

while True:
    key = os.read(0, 1)
    if key == b"\x1b":
        sequence = key
        while len(sequence) < 3:
            sequence += os.read(0, 3 - len(sequence))
        if sequence == b"\x1b[A":
            active = len(labels) if active == 1 else active - 1
        elif sequence == b"\x1b[B":
            active = 1 if active == len(labels) else active + 1
        render()
    elif key == b"\r":
        selected = labels[active - 1]
        os.write(1, f"SELECTED={selected}\n".encode())
        raise SystemExit(0 if selected == "Keep waiting" else 9)
"""


DELAYED_CONFIRM_MENU = r"""
import os
import select
import time
import tty

tty.setraw(0)

def render(active):
    lines = [
        "Additional safety checks",
        (
            "This request requires additional safety checks, which can take extra "
            "time. Hang tight or retry with a faster model for a quicker response, "
            "though it may be less capable of handling complex requests."
        ),
        ("›" if active == 1 else " ") + " 1. Retry with a faster model",
        ("›" if active == 2 else " ") + " 2. Keep waiting",
        ("›" if active == 3 else " ") + " 3. Learn more",
        "Press enter to confirm or esc to go back",
    ]
    os.write(1, ("\n".join(lines) + "\n").encode())

render(1)

arrow = b""
while len(arrow) < 3:
    arrow += os.read(0, 3 - len(arrow))
if arrow != b"\x1b[B":
    os.write(1, b"WRONG_ARROW=" + arrow.hex().encode() + b"\n")
    raise SystemExit(9)

ready, _, _ = select.select([0], [], [], 0.25)
if ready:
    early = os.read(0, 64)
    os.write(1, b"EARLY_BEFORE_SELECTION=" + early.hex().encode() + b"\n")
    raise SystemExit(9)

render(2)
key = os.read(0, 1)
if key != b"\r":
    os.write(1, b"WRONG_CONFIRM=" + key.hex().encode() + b"\n")
    raise SystemExit(9)

os.write(1, b"SELECTED=Keep waiting\n")
"""


PERSISTENT_REDRAW_MENU = r"""
import os
import select
import time
import tty

tty.setraw(0)

def render(active):
    lines = [
        "\x1b[1mAdditional safety checks\x1b[0m",
        "This request requires additional safety checks, which can take extra time.",
        ("›" if active == 1 else " ") + " 1. Retry with a faster model",
        ("›" if active == 2 else " ") + " 2. Keep waiting",
        ("›" if active == 3 else " ") + " 3. Learn more",
    ]
    os.write(1, ("\n".join(lines) + "\n").encode())

render(1)
arrow = b""
while len(arrow) < 3:
    arrow += os.read(0, 3 - len(arrow))
if arrow != b"\x1b[B":
    raise SystemExit(9)

render(2)
if os.read(0, 1) != b"\r":
    raise SystemExit(9)

extra = b""
deadline = time.monotonic() + 0.6
while time.monotonic() < deadline:
    render(2)
    ready, _, _ = select.select([0], [], [], 0.02)
    if ready:
        extra += os.read(0, 64)

if extra:
    os.write(1, b"EXTRA_KEYS=" + extra.hex().encode() + b"\n")
    raise SystemExit(9)

os.write(1, b"ONE_SHOT_OK\n")
"""


TWO_MATCH_EPISODES = r"""
import os
import time
import tty

tty.setraw(0)
os.write(1, b"\x1b[2J\x1b[HGoal blocked\n")
if os.read(0, 1) != b"X":
    raise SystemExit(9)

os.write(1, b"\x1b[2J\x1b[HWorking\n")
time.sleep(0.5)

os.write(1, b"\x1b[2J\x1b[HGoal blocked\n")
if os.read(0, 1) != b"X":
    raise SystemExit(9)

os.write(1, b"TWO_MATCHES_OK\n")
"""


class SafetyCheckSelectionTests(unittest.TestCase):
    def test_retry_prompt_moves_from_first_option_to_keep_waiting(self):
        prompt = """
Additional safety checks
This request requires additional safety checks, which can take extra time.
› 1. Retry with a faster model
  2. Keep waiting
  3. Learn more
"""

        selection = codex_watch.safety_check_option_indices(prompt)
        keys = codex_watch.keep_waiting_key_sequence(*selection)

        self.assertEqual(selection, (1, 2))
        self.assertEqual(
            keys,
            [codex_watch.ARROW_DOWN_SEQUENCE, codex_watch.RETURN_SEQUENCE],
        )
        self.assertEqual(option_selected_at_return(1, 3, keys), 2)

    def test_no_retry_prompt_keeps_first_option_selected(self):
        prompt = """
Additional safety checks
This request requires additional safety checks, which can take extra time.
› 1. Keep waiting
  2. Learn more
"""

        selection = codex_watch.safety_check_option_indices(prompt)
        keys = codex_watch.keep_waiting_key_sequence(*selection)

        self.assertEqual(selection, (1, 1))
        self.assertEqual(keys, [codex_watch.RETURN_SEQUENCE])
        self.assertEqual(option_selected_at_return(1, 2, keys), 1)

    def test_active_option_after_keep_waiting_moves_up_before_return(self):
        prompt = """
Additional safety checks
This request requires additional safety checks, which can take extra time.
  1. Retry with a faster model
  2. Keep waiting
› 3. Learn more
"""

        selection = codex_watch.safety_check_option_indices(prompt)
        keys = codex_watch.keep_waiting_key_sequence(*selection)

        self.assertEqual(selection, (3, 2))
        self.assertEqual(
            keys,
            [codex_watch.ARROW_UP_SEQUENCE, codex_watch.RETURN_SEQUENCE],
        )
        self.assertEqual(option_selected_at_return(3, 3, keys), 2)

    def test_ansi_styled_active_marker_is_identified_after_stripping(self):
        prompt = """
Additional safety checks
This request requires additional safety checks, which can take extra time.
\x1b[1m›\x1b[0m 1. Retry with a faster model
  2. Keep waiting
  3. Learn more
"""

        selection = codex_watch.safety_check_option_indices(
            codex_watch.strip_ansi(prompt)
        )

        self.assertEqual(selection, (1, 2))

    def test_unidentified_option_never_produces_a_submit_sequence(self):
        prompt = """
Additional safety checks
This request requires additional safety checks, which can take extra time.
Keep waiting
"""

        self.assertIsNone(codex_watch.safety_check_option_indices(prompt))


class SafetyCheckPtyIntegrationTests(unittest.TestCase):
    def watcher_env(self):
        env = os.environ.copy()
        env.pop("CODEX_WATCH_NO_SAFETY_CHECK_RETURN", None)
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        return env

    def run_menu(self, labels, active, fragmented=False):
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--match",
                "",
                "--",
                sys.executable,
                "-c",
                FAKE_CODEX_MENU,
                json.dumps(labels),
                str(active),
                "fragmented" if fragmented else "whole",
            ],
            capture_output=True,
            env=self.watcher_env(),
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
        self.assertIn(b"SELECTED=Keep waiting", result.stdout)

    def test_retry_menu_selects_second_option(self):
        self.run_menu(
            ["Retry with a faster model", "Keep waiting", "Learn more"],
            active=1,
        )

    def test_no_retry_menu_confirms_already_selected_first_option(self):
        self.run_menu(["Keep waiting", "Learn more"], active=1)

    def test_menu_moves_up_from_option_after_keep_waiting(self):
        self.run_menu(
            ["Retry with a faster model", "Keep waiting", "Learn more"],
            active=3,
        )

    def test_fragmented_utf8_and_ansi_still_select_keep_waiting(self):
        self.run_menu(
            ["Retry with a faster model", "Keep waiting", "Learn more"],
            active=1,
            fragmented=True,
        )

    def test_waits_for_redraw_confirming_keep_waiting_before_return(self):
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--match",
                "",
                "--",
                sys.executable,
                "-c",
                DELAYED_CONFIRM_MENU,
            ],
            capture_output=True,
            env=self.watcher_env(),
            timeout=5,
            check=False,
        )

        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("SELECTED=Keep waiting", output)
        self.assertNotIn("EARLY_BEFORE_SELECTION", output)
        self.assertNotIn("[codex-watch:", output)

    def test_persistent_redraw_never_resubmits_or_spams_status(self):
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--match",
                "",
                "--safety-check-cooldown",
                "0.1",
                "--",
                sys.executable,
                "-c",
                PERSISTENT_REDRAW_MENU,
            ],
            capture_output=True,
            env=self.watcher_env(),
            timeout=5,
            check=False,
        )

        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("ONE_SHOT_OK", output)
        self.assertNotIn("EXTRA_KEYS", output)
        self.assertNotIn("[codex-watch:", output)

    def test_ignored_arrow_never_receives_return(self):
        child = r"""
import os
import select
import tty

tty.setraw(0)
os.write(
    1,
    (
        "Additional safety checks\n"
        "This request requires additional safety checks, which can take extra time.\n"
        "› 1. Retry with a faster model\n"
        "  2. Keep waiting\n"
        "  3. Learn more\n"
    ).encode(),
)

arrow = b""
while len(arrow) < 3:
    arrow += os.read(0, 3 - len(arrow))
if arrow != b"\x1b[B":
    raise SystemExit(9)

ready, _, _ = select.select([0], [], [], 0.35)
extra = os.read(0, 64) if ready else b""
os.write(1, b"NO_RETURN\n" if not extra else b"UNCONFIRMED_RETURN\n")
raise SystemExit(0 if not extra else 9)
"""
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--match",
                "",
                "--",
                sys.executable,
                "-c",
                child,
            ],
            capture_output=True,
            env=self.watcher_env(),
            timeout=5,
            check=False,
        )

        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("NO_RETURN", output)
        self.assertNotIn("UNCONFIRMED_RETURN", output)

    def test_unrecognized_menu_receives_no_keys(self):
        child = r"""
import os
import select
import tty

tty.setraw(0)
os.write(
    1,
    b"Additional safety checks\n"
    b"This request requires additional safety checks, which can take extra time.\n"
    b"Keep waiting\n",
)
ready, _, _ = select.select([0], [], [], 0.3)
data = os.read(0, 64) if ready else b""
os.write(1, b"NO_KEYS\n" if not data else b"UNEXPECTED_KEYS\n")
raise SystemExit(0 if not data else 9)
"""
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--match",
                "",
                "--",
                sys.executable,
                "-c",
                child,
            ],
            capture_output=True,
            env=self.watcher_env(),
            timeout=5,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
        self.assertIn(b"NO_KEYS", result.stdout)
        self.assertNotIn(b"[codex-watch:", result.stdout)


class MatchReplyIntegrationTests(unittest.TestCase):
    def test_successful_match_is_not_scheduled_again(self):
        child = r"""
import os
import select
import time
import tty

tty.setraw(0)
os.write(1, b"Goal blocked\n")
received = b""
deadline = time.monotonic() + 1.4
while time.monotonic() < deadline:
    ready, _, _ = select.select([0], [], [], 0.05)
    if ready:
        received += os.read(0, 64)

os.write(1, b"RECEIVED=" + received.hex().encode() + b"\n")
raise SystemExit(0 if received == b"X" else 9)
"""
        env = os.environ.copy()
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--reply",
                "X",
                "--no-bracketed-paste",
                "--type-delay",
                "0",
                "--submit-key",
                "none",
                "--cooldown",
                "0.1",
                "--",
                sys.executable,
                "-c",
                child,
            ],
            capture_output=True,
            env=env,
            timeout=5,
            check=False,
        )

        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("RECEIVED=58", output)
        self.assertNotIn("[codex-watch:", output)

    def test_fragmented_redraw_does_not_repeat_successful_match(self):
        child = r"""
import os
import select
import time
import tty

tty.setraw(0)
os.write(1, b"Goal blocked\n")
if os.read(0, 1) != b"X":
    raise SystemExit(9)

extra = b""
deadline = time.monotonic() + 0.7
while time.monotonic() < deadline:
    os.write(1, b"Goal ")
    time.sleep(0.01)
    os.write(1, b"blocked\n")
    ready, _, _ = select.select([0], [], [], 0.02)
    if ready:
        extra += os.read(0, 64)

os.write(1, b"NO_REPEAT\n" if not extra else b"EXTRA=" + extra.hex().encode() + b"\n")
raise SystemExit(0 if not extra else 9)
"""
        env = os.environ.copy()
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--reply",
                "X",
                "--no-bracketed-paste",
                "--type-delay",
                "0",
                "--submit-key",
                "none",
                "--cooldown",
                "0.1",
                "--",
                sys.executable,
                "-c",
                child,
            ],
            capture_output=True,
            env=env,
            timeout=5,
            check=False,
        )

        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("NO_REPEAT", output)


class TerminalLifecycleTests(unittest.TestCase):
    def test_invalid_pattern_fails_before_starting_child(self):
        child = "raise SystemExit(91)"
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--pattern",
                "[",
                "--",
                sys.executable,
                "-c",
                child,
            ],
            capture_output=True,
            timeout=5,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(b"invalid --pattern", result.stderr)

    def test_sigterm_restores_outer_terminal_mode(self):
        master_fd, slave_fd = pty.openpty()
        original = termios.tcgetattr(slave_fd)
        process = None

        try:
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--match",
                    "",
                    "--",
                    sys.executable,
                    "-c",
                    "import time; time.sleep(10)",
                ],
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
            )

            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                current = termios.tcgetattr(slave_fd)
                if not current[3] & termios.ICANON and not current[3] & termios.ECHO:
                    break
                time.sleep(0.01)
            else:
                self.fail("watcher did not put the outer terminal into raw mode")

            time.sleep(0.05)
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=3), 128 + signal.SIGTERM)

            restored = termios.tcgetattr(slave_fd)
            for flag in (termios.ICANON, termios.ECHO, termios.ISIG, termios.IEXTEN):
                self.assertEqual(bool(restored[3] & flag), bool(original[3] & flag))
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            termios.tcsetattr(slave_fd, termios.TCSANOW, original)
            os.close(master_fd)
            os.close(slave_fd)


@unittest.skipUnless(shutil.which("tmux"), "tmux is required")
class TmuxIntegrationTests(unittest.TestCase):
    def run_in_tmux(self, watcher_options, child):
        session_name = f"codex-watch-test-{uuid.uuid4().hex[:10]}"
        watcher_command = shlex.join(
            [
                sys.executable,
                str(MODULE_PATH),
                *watcher_options,
                "--",
                sys.executable,
                "-c",
                child,
            ]
        )
        shell_command = (
            watcher_command
            + "; rc=$?; printf '\nWATCH_RC=%s\n' \"$rc\"; sleep 2"
        )
        output = ""

        try:
            subprocess.run(
                [
                    shutil.which("tmux"),
                    "new-session",
                    "-d",
                    "-s",
                    session_name,
                    "-x",
                    "180",
                    "-y",
                    "40",
                    "sh",
                    "-c",
                    shell_command,
                ],
                check=True,
                timeout=5,
            )

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                time.sleep(0.1)
                capture = subprocess.run(
                    [
                        shutil.which("tmux"),
                        "capture-pane",
                        "-p",
                        "-J",
                        "-t",
                        session_name,
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                output = capture.stdout
                if "WATCH_RC=" in output:
                    break
        finally:
            subprocess.run(
                [shutil.which("tmux"), "kill-session", "-t", session_name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

        return output

    def test_real_pane_confirms_selection_before_return(self):
        output = self.run_in_tmux(["--match", ""], DELAYED_CONFIRM_MENU)

        self.assertIn("WATCH_RC=0", output)
        self.assertIn("SELECTED=Keep waiting", output)
        self.assertNotIn("EARLY_BEFORE_SELECTION", output)
        self.assertNotIn("[codex-watch:", output)

    def test_match_rearms_only_after_it_leaves_the_real_pane(self):
        output = self.run_in_tmux(
            [
                "--reply",
                "X",
                "--no-bracketed-paste",
                "--type-delay",
                "0",
                "--submit-key",
                "none",
                "--cooldown",
                "0.1",
            ],
            TWO_MATCH_EPISODES,
        )

        self.assertIn("WATCH_RC=0", output)
        self.assertIn("TWO_MATCHES_OK", output)
        self.assertNotIn("[codex-watch:", output)


if __name__ == "__main__":
    unittest.main()
