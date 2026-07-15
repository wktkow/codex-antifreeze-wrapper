import errno
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest


REPO_DIR = pathlib.Path(__file__).resolve().parent
INSTALLER = REPO_DIR / "install.sh"


class InstallerRerunPromptTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = pathlib.Path(tempfile.mkdtemp())
        self.home = self.temp_dir / "home"
        self.install_dir = self.temp_dir / "bin"
        self.fake_bin = self.temp_dir / "fake-bin"
        self.shell = "/bin/zsh"
        self.home.mkdir()
        self.fake_bin.mkdir()

        self.archive = self.temp_dir / "source.tar.gz"
        with tarfile.open(self.archive, "w:gz") as snapshot:
            snapshot.add(REPO_DIR / "codex", arcname="snapshot/codex")
            snapshot.add(REPO_DIR / "codex-watch", arcname="snapshot/codex-watch")

        self.write_executable(
            self.fake_bin / "curl",
            """#!/usr/bin/env python3
import os
import pathlib
import shutil
import sys

output = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
shutil.copyfile(os.environ["TEST_INSTALL_ARCHIVE"], output)
""",
        )
        self.write_executable(self.fake_bin / "tmux", "#!/bin/sh\nexit 0\n")
        self.real_codex = self.fake_bin / "real-codex"
        self.write_executable(self.real_codex, "#!/bin/sh\nexit 0\n")

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def write_executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def installer_env(self, assume_yes=False):
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "SHELL": self.shell,
                "CODEX_HOME": str(self.home / ".codex"),
                "CODEX_REAL_BIN": str(self.real_codex),
                "CODEX_WRAPPER_INSTALL_DIR": str(self.install_dir),
                "PATH": f"{self.fake_bin}{os.pathsep}{env['PATH']}",
                "TEST_INSTALL_ARCHIVE": str(self.archive),
            }
        )
        if assume_yes:
            env["CODEX_WRAPPER_YES"] = "1"
        else:
            env.pop("CODEX_WRAPPER_YES", None)
        return env

    def install_with_yes(self):
        subprocess.run(
            ["/bin/bash", str(INSTALLER)],
            cwd=REPO_DIR,
            env=self.installer_env(assume_yes=True),
            capture_output=True,
            timeout=10,
            check=True,
        )

    def run_without_input(self, timeout=5):
        pid, master_fd = pty.fork()
        if pid == 0:
            os.chdir(REPO_DIR)
            os.execve(
                "/bin/bash",
                ["/bin/bash", str(INSTALLER)],
                self.installer_env(),
            )

        output = bytearray()
        deadline = time.monotonic() + timeout
        status = None
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master_fd], [], [], 0.05)
                if ready:
                    try:
                        chunk = os.read(master_fd, 8192)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        chunk = b""
                    output.extend(chunk)

                done_pid, status = os.waitpid(pid, os.WNOHANG)
                if done_pid == pid:
                    break
            else:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                self.fail(
                    "installer waited for unexpected input:\n"
                    + output.decode(errors="replace")
                )
        finally:
            os.close(master_fd)

        return os.waitstatus_to_exitcode(status), bytes(output)

    def write_manual_keymap(self):
        codex_dir = self.home / ".codex"
        codex_dir.mkdir(exist_ok=True)
        (codex_dir / "config.toml").write_text(
            """[tui.keymap.composer]
submit = ["enter", "ctrl-m"]

[tui.keymap.editor]
insert_newline = ["ctrl-j", "shift-enter", "alt-enter"]
"""
        )

    def test_rerun_repairs_old_managed_binaries_without_prompting(self):
        self.install_dir.mkdir()
        wrapper = self.install_dir / "codex"
        watcher = self.install_dir / "codex-watch"
        self.write_executable(
            wrapper,
            "#!/bin/sh\n# codex-antifreeze-wrapper managed executable\n"
            "echo BROKEN_OLD_WRAPPER\n",
        )
        self.write_executable(
            watcher,
            "#!/usr/bin/env python3\n"
            "# codex-antifreeze-wrapper managed watcher\n"
            "print('BROKEN_OLD_WATCHER')\n",
        )

        returncode, output = self.run_without_input()

        self.assertEqual(returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"[Y/n]", output)
        self.assertIn(b"updated codex and codex-watch", output)
        self.assertIn(b"restart existing Codex tmux sessions", output)
        self.assertEqual(wrapper.read_bytes(), (REPO_DIR / "codex").read_bytes())

        installed_watcher_lines = watcher.read_bytes().splitlines(keepends=True)
        source_watcher_lines = (REPO_DIR / "codex-watch").read_bytes().splitlines(
            keepends=True
        )
        self.assertTrue(installed_watcher_lines[0].startswith(b"#!"))
        self.assertEqual(installed_watcher_lines[1:], source_watcher_lines[1:])
        self.assertNotIn(b"BROKEN_OLD", wrapper.read_bytes())
        self.assertNotIn(b"BROKEN_OLD", watcher.read_bytes())
        self.assertTrue(os.access(wrapper, os.X_OK))
        self.assertTrue(os.access(watcher, os.X_OK))

        subprocess.run(["/bin/bash", "-n", str(wrapper)], check=True)
        subprocess.run(
            [str(watcher), "--help"],
            capture_output=True,
            timeout=5,
            check=True,
        )

    def test_rerun_repairs_partial_managed_install_without_prompting(self):
        original_install_dir = self.install_dir

        try:
            for existing_piece in ("wrapper", "watcher"):
                with self.subTest(existing_piece=existing_piece):
                    self.install_dir = self.temp_dir / f"bin-{existing_piece}"
                    self.install_dir.mkdir()

                    if existing_piece == "wrapper":
                        self.write_executable(
                            self.install_dir / "codex",
                            "#!/bin/sh\n"
                            "# codex-antifreeze-wrapper managed executable\n"
                            "echo BROKEN_PARTIAL_WRAPPER\n",
                        )
                    else:
                        self.write_executable(
                            self.install_dir / "codex-watch",
                            "#!/usr/bin/env python3\n"
                            "# codex-antifreeze-wrapper managed watcher\n"
                            "print('BROKEN_PARTIAL_WATCHER')\n",
                        )

                    returncode, output = self.run_without_input()

                    self.assertEqual(
                        returncode, 0, output.decode(errors="replace")
                    )
                    self.assertNotIn(b"[Y/n]", output)
                    self.assertIn(b"updated codex and codex-watch", output)
                    self.assertEqual(
                        (self.install_dir / "codex").read_bytes(),
                        (REPO_DIR / "codex").read_bytes(),
                    )
                    self.assertEqual(
                        (self.install_dir / "codex-watch")
                        .read_bytes()
                        .splitlines(keepends=True)[1:],
                        (REPO_DIR / "codex-watch")
                        .read_bytes()
                        .splitlines(keepends=True)[1:],
                    )
        finally:
            self.install_dir = original_install_dir

    def test_managed_rerun_refreshes_without_prompting(self):
        self.install_with_yes()
        zshrc = self.home / ".zshrc"
        zshrc.write_text(
            zshrc.read_text()
            .replace(str(self.install_dir), "/stale")
            .replace("codex-antifreeze-wrapper", "codex-antifreeze-shit-wrapper")
        )

        returncode, output = self.run_without_input()

        self.assertEqual(returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"[Y/n]", output)
        self.assertIn(str(self.install_dir), zshrc.read_text())
        self.assertIn("codex-antifreeze-wrapper", zshrc.read_text())
        self.assertNotIn("codex-antifreeze-shit-wrapper", zshrc.read_text())
        self.assertIn(b"updated codex and codex-watch", output)

    def test_rerun_does_not_reoffer_absent_optional_pieces(self):
        self.install_with_yes()
        (self.home / ".zshrc").unlink()
        (self.home / ".codex" / "config.toml").unlink()

        returncode, output = self.run_without_input()

        self.assertEqual(returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"[Y/n]", output)
        self.assertFalse((self.home / ".zshrc").exists())
        self.assertFalse((self.home / ".codex" / "config.toml").exists())

    def test_equivalent_manual_pieces_skip_fresh_install_prompts(self):
        self.write_manual_keymap()
        zshrc = self.home / ".zshrc"
        alias_line = f"alias codex='{self.install_dir}/codex'\n"
        zshrc.write_text(alias_line)

        returncode, output = self.run_without_input()

        self.assertEqual(returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"[Y/n]", output)
        self.assertEqual(zshrc.read_text(), alias_line)

    def test_existing_empty_manual_keymap_table_is_not_reoffered(self):
        codex_dir = self.home / ".codex"
        codex_dir.mkdir()
        config_file = codex_dir / "config.toml"
        config_file.write_text("[tui.keymap.composer]\n")
        zshrc = self.home / ".zshrc"
        zshrc.write_text(f"alias codex='{self.install_dir}/codex'\n")

        returncode, output = self.run_without_input()

        self.assertEqual(returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"[Y/n]", output)
        self.assertEqual(config_file.read_text(), "[tui.keymap.composer]\n")

    def test_incompatible_manual_keymap_warns_without_prompting(self):
        codex_dir = self.home / ".codex"
        codex_dir.mkdir()
        config_file = codex_dir / "config.toml"
        config_file.write_text(
            "[tui.keymap.composer]\nsubmit = [\"enter\"]\n"
        )
        (self.home / ".zshrc").write_text(
            f"alias codex='{self.install_dir}/codex'\n"
        )

        returncode, output = self.run_without_input()

        self.assertEqual(returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"[Y/n]", output)
        self.assertIn(b"merge these values manually", output)
        self.assertNotIn("ctrl-m", config_file.read_text())

    def test_config_only_managed_install_is_an_update_without_prompts(self):
        zshrc = self.home / ".zshrc"
        zshrc.write_text(
            "# >>> codex-antifreeze-wrapper >>>\n"
            "alias codex='/stale/codex'\n"
            "# <<< codex-antifreeze-wrapper <<<\n"
        )

        returncode, output = self.run_without_input()

        self.assertEqual(returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"[Y/n]", output)
        self.assertIn(b"updated codex and codex-watch", output)
        self.assertIn(str(self.install_dir), zshrc.read_text())

    def test_partial_bash_alias_is_completed_instead_of_misclassified(self):
        self.shell = "/bin/bash"
        self.write_manual_keymap()
        (self.home / ".bash_profile").write_text("")
        (self.home / ".profile").write_text(
            f"alias codex='{self.install_dir}/codex'\n"
        )

        self.install_with_yes()

        self.assertIn(str(self.install_dir), (self.home / ".bashrc").read_text())
        self.assertIn(
            str(self.install_dir), (self.home / ".bash_profile").read_text()
        )

    def test_malformed_later_alias_block_fails_before_any_install_write(self):
        zshrc = self.home / ".zshrc"
        original_zshrc = (
            "# >>> codex-antifreeze-wrapper >>>\n"
            "alias codex='/stale/codex'\n"
            "# <<< codex-antifreeze-wrapper <<<\n"
        )
        zshrc.write_text(original_zshrc)
        fish_dir = self.home / ".config" / "fish"
        fish_dir.mkdir(parents=True)
        (fish_dir / "config.fish").write_text(
            "# >>> codex-antifreeze-wrapper >>>\n"
            "alias codex '/broken/codex'\n"
        )

        returncode, output = self.run_without_input()

        self.assertNotEqual(returncode, 0)
        self.assertIn(b"malformed managed block", output)
        self.assertFalse(self.install_dir.exists())
        self.assertEqual(zshrc.read_text(), original_zshrc)

    def test_unrelated_watcher_is_never_overwritten(self):
        self.install_with_yes()
        wrapper_before = (self.install_dir / "codex").read_bytes()
        watcher = self.install_dir / "codex-watch"
        watcher.write_text("#!/bin/sh\necho unrelated\n")
        watcher.chmod(0o755)

        returncode, output = self.run_without_input()

        self.assertNotEqual(returncode, 0)
        self.assertIn(b"refusing to overwrite unrelated executable", output)
        self.assertEqual((self.install_dir / "codex").read_bytes(), wrapper_before)
        self.assertEqual(watcher.read_text(), "#!/bin/sh\necho unrelated\n")


if __name__ == "__main__":
    unittest.main()
