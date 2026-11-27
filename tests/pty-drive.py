#!/usr/bin/env python3
"""Run a command inside a pseudo-terminal and answer its secret prompts.

relevio's archive refuses to ask for a key without a real terminal, and age
reads passphrases from /dev/tty, so a pipe cannot drive them. This plays the
person at the terminal, for tests and throwaway test archives only:

  pty-drive.py [--pass-file F] [--recovery-file F] [--save-recovery F]
               [--log F] [--timeout S] -- <command> [args...]

  passphrase prompts (age's "...passphrase...:")  answered with --pass-file
  "Recovery key (hidden):"                         answered with the
      AGE-SECRET-KEY-1 line the command showed earlier, else --recovery-file
  --save-recovery F   writes the AGE-SECRET-KEY-1 line the command showed
  --log F             the full screen goes to F (mode 600) instead of stdout

Last line printed: "pty-drive: exit=<code> passphrase_prompts=<n>
recovery_prompts=<n>". Exit code: the command's, 128+signal when a signal
ended it, or 124 on timeout.
"""
import argparse
import os
import pty
import re
import select
import sys
import time

PASS_RE = re.compile(rb"passphrase[^\n]*:\s*$", re.I)
REC_RE = re.compile(rb"Recovery key \(hidden\):\s*$")
SECRET_RE = re.compile(rb"AGE-SECRET-KEY-1[0-9A-Z]+")


def read_secret(path):
    if not path:
        return None
    with open(path, "rb") as f:
        return f.read().strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pass-file")
    ap.add_argument("--recovery-file")
    ap.add_argument("--save-recovery")
    ap.add_argument("--log")
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        ap.error("no command given")
    passphrase = read_secret(a.pass_file)
    recovery = read_secret(a.recovery_file)

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)

    screen = b""   # everything shown, for the log and the recovery line
    pending = b""  # text since the last answer, where prompts are looked for
    counts = {"passphrase": 0, "recovery": 0}
    deadline = time.time() + a.timeout
    timed_out = False
    while True:
        if time.time() > deadline:
            timed_out = True
            os.kill(pid, 9)
            break
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        screen += chunk
        pending += chunk
        shown = SECRET_RE.search(screen)
        if PASS_RE.search(pending[-200:]) and passphrase is not None:
            counts["passphrase"] += 1
            pending = b""
            os.write(fd, passphrase + b"\r")
        elif REC_RE.search(pending[-200:]):
            answer = shown.group(0) if shown else recovery
            if answer is None:
                continue
            counts["recovery"] += 1
            pending = b""
            os.write(fd, answer + b"\r")

    _, status = os.waitpid(pid, 0)
    if timed_out:
        code = 124
    elif os.WIFEXITED(status):
        code = os.WEXITSTATUS(status)
    else:
        code = 128 + os.WTERMSIG(status)  # the shell's convention: which signal

    shown = SECRET_RE.search(screen)
    if a.save_recovery and shown:
        fdw = os.open(a.save_recovery, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fdw, "wb") as f:
            f.write(shown.group(0) + b"\n")
    if a.log:
        fdw = os.open(a.log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fdw, "wb") as f:
            f.write(screen)
    else:
        sys.stdout.buffer.write(screen)
    print(f"\npty-drive: exit={code} passphrase_prompts={counts['passphrase']} recovery_prompts={counts['recovery']}")
    sys.exit(code)


if __name__ == "__main__":
    main()
