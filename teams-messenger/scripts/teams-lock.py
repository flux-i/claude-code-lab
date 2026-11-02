#!/usr/bin/env python3
"""Serialize Teams operations with an OS lock that is released after a crash."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys

def main():
    directory = Path(os.environ.get("TEAMS_WEB_APP_DIR", str(Path.home() / "Library/Application Support/Codex Teams Messenger")))
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    fd = os.open(directory / "operation.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({"verified": False, "error": "operation_in_progress", "message": "Another Teams operation is active; this command did not run."}))
            return 1
        os.fchmod(fd, 0o600)
        os.ftruncate(fd, 0)
        os.write(fd, json.dumps({"pid": os.getpid()}).encode())
        # Passing the lock descriptor keeps the lock held if the parent exits first.
        return subprocess.call(["node", str(Path(__file__).resolve().with_name("teams-api.cjs")), *sys.argv[1:]], pass_fds=(fd,))
    finally:
        os.close(fd)

if __name__ == "__main__":
    sys.exit(main())
