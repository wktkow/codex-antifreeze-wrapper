import importlib.machinery
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import unittest


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
    elif key == b"\r":
        selected = labels[active - 1]
        os.write(1, f"SELECTED={selected}\n".encode())
        raise SystemExit(0 if selected == "Keep waiting" else 9)
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


if __name__ == "__main__":
    unittest.main()
