#!/usr/bin/env python3
"""Screen tests for the Cavey DevKit terminal UI.

Runs the real React UI in a pseudo-terminal, renders the output with pyte and
checks what a person would see. PowerShell and the GitHub CLI are replaced by
test doubles (fakes/), and the project is a throwaway Git repository with a
local origin, so the tests need no network, Windows or GitHub account.

    pip install pyte
    python3 tools/devkit/test/ui/ui_snapshots.py [--out DIR]

Linux/macOS only (uses pty) and needs PowerShell 7 (`pwsh`) on PATH: data
commands such as `branches --json` run the real engine. Screens are written
to --out for review.
"""
import argparse
import fcntl
import json
import os
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import traceback

import pyte

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.abspath(os.path.join(HERE, "..", ".."))
FAKES = os.path.join(HERE, "fakes")
ESC, ENTER, CTRL_O, CTRL_C, CTRL_U = "\x1b", "\r", "\x0f", "\x03", "\x15"
CORNERS = "╭╮╰╯"


class Screen:
    """A running DevKit in a pseudo-terminal of a fixed size."""

    # Set by --bundle: run the esbuild bundle (dist/devkit.mjs) the launcher uses.
    bundle = False

    def __init__(self, env, cols=100, rows=34):
        self.cols, self.rows = cols, rows
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(APP)
            entry = ["dist/devkit.mjs"] if Screen.bundle else ["node_modules/tsx/dist/cli.mjs", "src/main.tsx"]
            os.execvpe("node", ["node", *entry], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.03)
            if ready:
                try:
                    self.stream.feed(os.read(self.fd, 65536))
                except OSError:
                    return

    def text(self):
        return "\n".join(line.rstrip() for line in self.screen.display)

    def wait_for(self, needle, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.1)
            if needle in self.text():
                return
        raise AssertionError(f"timed out waiting for {needle!r}\n{self.text()}")

    def wait_gone(self, needle, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.1)
            if needle not in self.text():
                return
        raise AssertionError(f"{needle!r} is still on screen\n{self.text()}")

    def type(self, keys):
        # One key per write: a single multi-character write is read as a paste.
        for key in [keys] if keys.startswith(ESC) else list(keys):
            os.write(self.fd, key.encode())
            self.pump(0.04)

    def click(self, needle):
        """Left-click the first cell of `needle` (SGR mouse protocol)."""
        for row, line in enumerate(self.screen.display):
            col = line.find(needle)
            if col >= 0:
                x, y = col + 2, row + 1
                os.write(self.fd, f"\x1b[<0;{x};{y}M".encode())
                self.pump(0.05)
                os.write(self.fd, f"\x1b[<0;{x};{y}m".encode())
                self.pump(0.2)
                return
        raise AssertionError(f"nothing to click: {needle!r}\n{self.text()}")

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def check_layout(screen):
    """Boxes must not overlap: a bordered row never has a corner in its middle,
    and every box that opens on screen also closes."""
    lines = screen.text().split("\n")
    for line in lines:
        body = line.strip()
        if body.startswith("│") and any(c in body[1:-1] for c in CORNERS):
            raise AssertionError(f"overlapping boxes on row: {line!r}\n{screen.text()}")
    tops = sum(line.strip().startswith("╭") for line in lines)
    bottoms = sum(line.strip().startswith("╰") for line in lines)
    # The welcome box may scroll off the top, so a closing border can outnumber openings.
    if tops > bottoms:
        raise AssertionError(f"a box is cut off at the bottom\n{screen.text()}")


def make_project(root):
    """A Git repository with a local bare origin and a few branches."""
    env = dict(os.environ, GIT_AUTHOR_NAME="Tester", GIT_AUTHOR_EMAIL="t@example.com",
               GIT_COMMITTER_NAME="Tester", GIT_COMMITTER_EMAIL="t@example.com")
    origin, work = os.path.join(root, "origin.git"), os.path.join(root, "cavey-player")

    def git(*args, cwd=work):
        subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True)

    subprocess.run(["git", "init", "--bare", "-b", "main", origin], check=True, capture_output=True)
    os.makedirs(work)
    git("init", "-b", "main")
    git("remote", "add", "origin", origin)
    for branch in ["main", "feature/alpha", "feature/beta"]:
        if branch != "main":
            git("checkout", "-b", branch)
        with open(os.path.join(work, "README.md"), "a") as handle:
            handle.write(branch + "\n")
        git("add", ".")
        git("commit", "-m", "work on " + branch)
        git("push", "origin", branch)
    git("checkout", "main")
    return work


# ── Scenarios ──────────────────────────────────────────────────────────

def welcome_palette_and_shortcuts(s):
    s.wait_for("Cavey DevKit")
    s.wait_for("? for shortcuts")
    s.wait_for("cavey-player · main ✓")
    check_layout(s)
    s.type("/")
    s.wait_for("/help")
    text = s.text()
    for name in ["/build", "/rebuild", "/releases", "/recover", "/run", "/logs", "/doctor", "/help"]:
        assert name in text, name
    assert "/cache" not in text, "secondary commands must stay hidden on a bare /"
    s.type("ca")
    s.wait_for("Source build cache")
    s.type(ESC)
    s.wait_gone("Source build cache")
    s.type("?")
    s.wait_for("Ctrl+O")
    check_layout(s)


def build_wizard_back_and_cancel(s):
    s.wait_for("? for shortcuts")
    s.type("/build")
    s.type(ENTER)
    s.wait_for("Build which branch?")
    assert "feature/alpha" in s.text() and "feature/beta" in s.text()
    check_layout(s)
    s.type("alph")
    s.wait_gone("feature/beta")
    s.type(ENTER)
    s.wait_for("What kind of build?")
    assert "⏺ Branch  feature/alpha" in s.text()
    assert "4. Android APK" in s.text()
    s.type("1")
    s.wait_for("Build locally?")
    text = s.text()
    assert "origin/feature/alpha" in text and "Checks" in text and "1. Yes, build" in text
    assert "⏺ Local build" in text
    check_layout(s)
    s.type(ESC)
    s.wait_for("What kind of build?")
    assert "⏺ Local build" not in s.text(), "going back must remove the step line"
    s.type(ESC)
    s.wait_for("Build which branch?")
    s.type("working")
    s.type(ENTER)
    s.wait_for("Build your working copy?")
    assert "uncommitted changes included" in s.text() and "Build faster" in s.text()
    s.type(ESC)
    s.wait_for("Build which branch?")
    s.type(ESC)
    s.wait_for("Cancelled")
    s.wait_for("? for shortcuts")


def name_channel_and_note(s):
    s.wait_for("? for shortcuts")
    s.type("/build")
    s.type(ENTER)
    s.wait_for("Build which branch?")
    s.type("alph")
    s.wait_gone("feature/beta")
    s.type(ENTER)
    s.wait_for("What kind of build?")
    s.type("2")
    s.wait_for("Name the new channel")
    assert "devkit/alpha (press Enter)" in s.text()
    check_layout(s)
    s.type("alpha/20261118-ab12")
    s.type(ENTER)
    s.wait_for("already exists")
    assert "Name the new channel" in s.text(), "a taken name keeps the naming step open"
    s.type(CTRL_U)
    s.type(ENTER)
    s.wait_for("Build and publish a new test release?")
    text = s.text()
    assert "⏺ Channel  devkit/alpha" in text and "devkit/alpha (new)" in text
    assert "then a launch check" in text
    s.type("2")
    s.wait_for("Note for testers")
    s.type("check the mixer")
    s.type(ENTER)
    s.wait_for("⏺ Note  check the mixer")
    s.wait_for("⏺ Build feature/alpha → new test release")
    s.wait_for("Failed · exit 1", timeout=20)


def failing_build_output(s):
    s.wait_for("? for shortcuts")
    s.type("/build --branch main --local --yes")
    s.type(ENTER)
    s.wait_for("esc to interrupt")
    s.wait_for("Failed · exit 1", timeout=20)
    text = s.text()
    assert "⏺ Build main · local" in text
    assert "✗ Compile" in text and "✓ Source" in text and "– Checks" in text
    assert "ERROR: lib/main.dart:12:3: Undefined name 'foo'" in text, "errors stay visible when collapsed"
    assert "lines (click or ctrl+o to expand)" in text
    assert "@@CAVEY_STAGE" not in text
    check_layout(s)
    s.click("lines (click or ctrl+o to expand)")
    s.wait_for("(click to collapse)")
    s.click("(click to collapse)")
    s.wait_for("to expand)")
    s.type(CTRL_O)
    s.wait_gone("to expand)")
    s.type("echo hello-from-shell")
    s.type(ENTER)
    s.wait_for("⏺ PowerShell(echo hello-from-shell)")
    s.wait_for("hello-from-shell\n")


def build_card_queue_and_rebuild(s):
    s.wait_for("? for shortcuts")
    s.type("/build --branch feature/alpha --local --yes")
    s.type(ENTER)
    s.wait_for("esc to interrupt")
    s.type("echo queued-one")
    s.type(ENTER)
    s.wait_for("queued: echo queued-one")
    s.wait_for("Built 0.4.0.7 · local", timeout=20)
    text = s.text()
    assert "CavePlayer-Setup.exe" in text and "48.3 MB" in text
    assert "Run" in text and "Open folder" in text and "Build again" in text
    assert "Copy link" not in text, "local builds have no link"
    assert "✓ Verify" in text
    s.wait_for("⏺ PowerShell(echo queued-one)")
    s.wait_gone("queued: echo queued-one")
    s.type("/rebuild")
    s.type(ENTER)
    s.wait_for("Build again?")
    assert "Build feature/alpha · local" in s.text()
    check_layout(s)
    s.type(ESC)
    s.wait_for("Cancelled")


def interrupt_drops_queue(s):
    s.wait_for("? for shortcuts")
    s.type("/build --branch main --local --yes")
    s.type(ENTER)
    s.wait_for("esc to interrupt")
    s.type("echo never")
    s.type(ENTER)
    s.wait_for("queued: echo never")
    s.type(ESC)
    s.wait_for("Interrupted")
    s.wait_gone("queued: echo never")
    s.pump(1.5)
    assert "PowerShell(echo never)" not in s.text()


def releases_manager(s):
    s.wait_for("? for shortcuts")
    s.type("/releases")
    s.type(ENTER)
    s.wait_for("What do you want to do with test releases?")
    s.type("1")
    s.wait_for("Which channel?")
    text = s.text()
    assert "devkit/alpha/20261118-ab12" in text and "1 hidden" in text
    assert "feature/beta" in text and "CI · 1 version" in text
    s.type("beta")
    s.wait_gone("devkit/alpha")
    s.type(ENTER)
    s.wait_for("GitHub Actions")
    assert "Update from a branch" not in s.text(), "CI channels are view-only"
    assert "Try it on this computer" in s.text()
    s.type(ESC)
    s.wait_for("Which channel?")
    s.type(ENTER)
    s.wait_for("Undo rollback")
    s.type("5")
    s.wait_for("Undo the rollback of")
    check_layout(s)


def small_terminal(s):
    s.wait_for("? for shortcuts")
    s.type("/build")
    s.type(ENTER)
    s.wait_for("Build which branch?")
    s.wait_for("Esc to go back")
    assert "Working copy" in s.text()
    check_layout(s)
    s.type("alph")
    s.wait_gone("feature/beta")
    s.type(ENTER)
    s.type("2")
    s.wait_for("Name the new channel")
    check_layout(s)
    s.type(ENTER)
    s.wait_for("Build and publish a new test release?")
    s.wait_for("4. No, go back")
    check_layout(s)


def double_ctrl_c_exits(s):
    s.wait_for("? for shortcuts")
    s.type(CTRL_C)
    s.wait_for("Press Ctrl+C again to exit")
    s.type(CTRL_C)
    end = time.time() + 5
    while time.time() < end:
        s.pump(0.1)
        if os.waitpid(s.pid, os.WNOHANG)[0]:
            return
    raise AssertionError("DevKit did not exit after a second Ctrl+C")


SCENARIOS = [
    ("welcome_palette_and_shortcuts", welcome_palette_and_shortcuts, (100, 34)),
    ("build_wizard_back_and_cancel", build_wizard_back_and_cancel, (100, 34)),
    ("name_channel_and_note", name_channel_and_note, (100, 34)),
    ("failing_build_output", failing_build_output, (100, 34)),
    ("build_card_queue_and_rebuild", build_card_queue_and_rebuild, (100, 34)),
    ("interrupt_drops_queue", interrupt_drops_queue, (100, 34)),
    ("releases_manager", releases_manager, (100, 34)),
    ("small_terminal", small_terminal, (80, 24)),
    ("double_ctrl_c_exits", double_ctrl_c_exits, (100, 34)),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "devkit-ui-screens"))
    parser.add_argument("-k", default="", help="run scenarios whose name contains this text")
    parser.add_argument("--bundle", action="store_true", help="test dist/devkit.mjs (run `npm run build` first)")
    args = parser.parse_args()
    Screen.bundle = args.bundle
    os.makedirs(args.out, exist_ok=True)
    failures = 0
    for name, scenario, (cols, rows) in SCENARIOS:
        if args.k not in name:
            continue
        root = tempfile.mkdtemp(prefix="devkit-ui-")
        screen = None
        try:
            project = make_project(root)
            data = os.path.join(root, "localappdata")
            os.makedirs(os.path.join(data, "CaveyDevKit"))
            with open(os.path.join(data, "CaveyDevKit", "config.json"), "w") as handle:
                json.dump({"projectRoot": project}, handle)
            env = dict(os.environ, TERM="xterm-256color", LOCALAPPDATA=data, CAVEY_DEVKIT_ANY_ORIGIN="1",
                       TEMP=tempfile.gettempdir(), PATH=FAKES + os.pathsep + os.environ["PATH"])
            env.pop("WT_SESSION", None)
            screen = Screen(env, cols, rows)
            scenario(screen)
            print(f"PASS {name}")
        except Exception:
            failures += 1
            print(f"FAIL {name}")
            traceback.print_exc()
        finally:
            if screen:
                with open(os.path.join(args.out, name + ".txt"), "w") as handle:
                    handle.write(screen.text() + "\n")
                screen.close()
            shutil.rmtree(root, ignore_errors=True)
    print(f"Screens: {args.out}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
