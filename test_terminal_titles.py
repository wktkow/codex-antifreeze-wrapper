import errno
import os
import pathlib
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


REPO_DIR = pathlib.Path(__file__).resolve().parent
TITLE_RE = re.compile(rb"\x1b\](?:0|2);(.*?)(?:\x07|\x1b\\)", re.DOTALL)
TITLES = [
    f"{frame} Codex — working #{{literal}}; title test"
    for frame in ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴"]
] + ["✓ Codex — done"]


@unittest.skipUnless(shutil.which("tmux"), "tmux is required")
class TerminalTitleIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.tmux = [shutil.which("tmux"), "-L",
                     f"codex-title-test-{uuid.uuid4().hex[:10]}", "-f", "/dev/null"]
        self.clients = []
        self.output = b""
        self.ready = self.root / "ready"
        self.trigger = self.root / "start"
        fake_tmux = self.root / "tmux"
        fake_tmux.write_text(f"#!/bin/sh\nexec {shlex.join(self.tmux)} \"$@\"\n")
        fake_tmux.chmod(0o755)
        self.child = self.root / "fake-codex"
        self.child.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, time\n"
            f"pathlib.Path({str(self.ready)!r}).touch()\n"
            f"trigger = pathlib.Path({str(self.trigger)!r})\n"
            "while not trigger.exists(): time.sleep(0.01)\n"
            f"for index, title in enumerate({TITLES!r}):\n"
            "    command = b'0' if index % 3 == 0 else b'2'\n"
            "    end = b'\\x07' if index % 2 == 0 else b'\\x1b\\\\'\n"
            "    data = b'\\x1b]' + command + b';' + title.encode() + end\n"
            "    for part in (data[:1], data[1:5], data[5:6], data[6:-1], data[-1:]):\n"
            "        os.write(1, part)\n"
            "        time.sleep(0.005)\n"
            "    time.sleep(0.1)\n"
            "while True: time.sleep(1)\n"
        )
        self.child.chmod(0o755)
        self.env = {name: value for name, value in os.environ.items()
                    if not name.startswith(("CODEX_WATCH_", "CODEX_TMUX_"))
                    and name not in {"TMUX", "TMUX_PANE"}}
        self.env.update({
            "TERM": "xterm-256color",
            "CODEX_REAL_BIN": str(self.child),
            "CODEX_WATCH_BIN": str(REPO_DIR / "codex-watch"),
            "CODEX_TMUX_BIN": str(fake_tmux),
            "CODEX_TMUX_DIR": str(self.root),
            "CODEX_TMUX_SESSION": "codex-title-test",
            "CODEX_LINUX_DEP_CHECK": "0",
        })
        self.run_tmux("new-session", "-d", "-s", "unrelated", "sleep 60")
        self.run_tmux("set-option", "-g", "set-titles", "off")
        self.run_tmux("set-option", "-g", "set-titles-string", "original-global-title")
        self.run_tmux("set-option", "-t", "=unrelated:", "set-titles", "off")
        self.run_tmux("set-option", "-t", "=unrelated:", "set-titles-string",
                      "original-unrelated-title")
        # Older tmux versions always accept application titles and do not have
        # this option. -q keeps the integration test usable with those versions.
        self.run_tmux("set-option", "-wqg", "allow-set-title", "off")

    def tearDown(self):
        self.run_tmux("kill-server", check=False)
        for pid, master in self.clients:
            os.close(master)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if os.waitpid(pid, os.WNOHANG)[0]:
                    break
                time.sleep(0.01)
            else:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
        self.temp.cleanup()

    def run_tmux(self, *arguments, check=True):
        return subprocess.run([*self.tmux, *arguments], env=self.env,
                              capture_output=True, text=True, check=check, timeout=5)

    def start_client(self, command):
        pid, master = pty.fork()
        if pid == 0:
            os.execvpe(command[0], command, self.env)
        self.clients.append((pid, master))
        self.master = master

    def read_until(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate(self.output):
                return
            if select.select([self.master], [], [], 0.05)[0]:
                try:
                    data = os.read(self.master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                self.output += data
        self.fail(f"terminal condition timed out: {self.output!r}")

    def assert_title_frames(self):
        # Wait for a title from the attached client before starting animation.
        # This also confirms Codex has started after configuring its session.
        self.read_until(lambda output: self.ready.exists() and TITLE_RE.search(output))
        self.trigger.touch()
        self.read_until(lambda output: TITLES[-1].encode() in TITLE_RE.findall(output))
        observed = [title.decode() for title in TITLE_RE.findall(self.output)
                    if title.decode() in TITLES]
        self.assertEqual(observed, TITLES)
        self.assertEqual(self.run_tmux("show-options", "-gv", "set-titles").stdout.strip(),
                         "off")
        self.assertEqual(self.run_tmux("show-options", "-gv", "set-titles-string").stdout.strip(),
                         "original-global-title")
        self.assertEqual(self.run_tmux("show-options", "-v", "-t", "=unrelated:",
                                      "set-titles").stdout.strip(), "off")
        self.assertEqual(self.run_tmux("show-options", "-v", "-t", "=unrelated:",
                                      "set-titles-string").stdout.strip(),
                         "original-unrelated-title")

    def test_new_session_forwards_fragmented_unicode_animation(self):
        self.start_client([str(REPO_DIR / "codex")])
        self.assert_title_frames()

    def test_title_forwarding_works_with_watcher_disabled(self):
        self.env["CODEX_WATCH_DISABLE"] = "1"
        self.start_client([str(REPO_DIR / "codex"), "resume", "--last"])
        self.assert_title_frames()

    def test_launch_inside_existing_tmux_forwards_animation(self):
        self.run_tmux("new-session", "-d", "-s", "codex-title-test",
                      shlex.join([str(REPO_DIR / "codex")]))
        self.start_client([*self.tmux, "attach-session", "-t", "=codex-title-test"])
        self.assert_title_frames()
        sessions = self.run_tmux("list-sessions", "-F", "#{session_name}").stdout.splitlines()
        self.assertEqual(sorted(sessions), ["codex-title-test", "unrelated"])

    def test_reattach_enables_titles_without_restarting_codex(self):
        # Model a session started with the old launcher: the watcher is already
        # running, but tmux is still inheriting set-titles=off.
        self.run_tmux("new-session", "-d", "-s", "codex-title-test",
                      shlex.join([sys.executable, str(REPO_DIR / "codex-watch"),
                                  "--match", "", "--", str(self.child)]))
        pane_pid = self.run_tmux("display-message", "-p", "-t", "=codex-title-test:",
                                 "#{pane_pid}").stdout
        self.start_client([str(REPO_DIR / "codex")])
        self.read_until(lambda output: b"Attach to it or create a new one?" in output)
        os.write(self.master, b"\r")
        self.assert_title_frames()
        self.assertEqual(self.run_tmux("display-message", "-p", "-t", "=codex-title-test:",
                                       "#{pane_pid}").stdout, pane_pid)


if __name__ == "__main__":
    unittest.main()
