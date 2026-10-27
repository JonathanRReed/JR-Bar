#!/usr/bin/env python3
"""Submit an archive, recover completed uploads, and bound Apple's wait."""

import argparse
import datetime
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TERMINAL = {"Accepted", "Invalid", "Rejected"}
CRASHES = {-4, -6, -10, -11, 132, 134, 138, 139}


class NotaryError(Exception):
    pass


class Notarizer:
    def __init__(self, tool, profile, deadline, response, *, clock=time.monotonic,
                 sleep=time.sleep, runner=subprocess.run):
        self.tool = tool
        self.profile = profile
        self.deadline = deadline
        self.response = response
        self.clock = clock
        self.sleep = sleep
        self.runner = runner
        self.ids = []

    def remaining(self):
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            ids = ", ".join(self.ids) or "not yet known; inspect upload receipts and history"
            raise NotaryError(f"Notarization deadline reached. Submissions: {ids}. "
                              "Apple may still be processing. No further upload was attempted.")
        return remaining

    def pause(self):
        self.sleep(min(15, self.remaining()))

    def command(self, *arguments):
        timeout = self.remaining()
        # Private, distinct receipts preserve crashes without printing transport data.
        with tempfile.NamedTemporaryFile(prefix=f"{self.response}.{arguments[0]}-stdout.",
                                         delete=False) as stdout, \
             tempfile.NamedTemporaryFile(prefix=f"{self.response}.{arguments[0]}-stderr.",
                                         delete=False) as stderr:
            print(f"Notary {arguments[0]} receipts: {stdout.name}, {stderr.name}", file=sys.stderr)
            try:
                result = self.runner([self.tool, "notarytool", *arguments,
                                      "--keychain-profile", self.profile,
                                      "--output-format", "json"],
                                     stdout=stdout, stderr=stderr, timeout=timeout, check=False)
            except subprocess.TimeoutExpired:
                self.remaining()
                raise NotaryError("Notary command timed out; inspect its private receipts.") from None
        try:
            data = json.loads(Path(stdout.name).read_text())
        except (ValueError, OSError):
            data = None
        return result.returncode, data

    @staticmethod
    def submission_id(row):
        value = row.get("id") if isinstance(row, dict) else None
        return value if isinstance(value, str) and value and not any(c.isspace() for c in value) else None

    def info(self, submission):
        code, data = self.command("info", submission)
        if (code == 0 and self.submission_id(data) == submission
                and data.get("status") in TERMINAL | {"In Progress"}):
            return data
        return None

    def recover(self, file, start, end):
        for attempt in range(3):
            code, data = self.command("history")
            matches = []
            if code == 0 and isinstance(data, dict) and isinstance(data.get("history"), list):
                for row in data["history"]:
                    if not isinstance(row, dict) or row.get("name") != file.name:
                        continue
                    try:
                        created = datetime.datetime.fromisoformat(row["createdDate"].replace("Z", "+00:00")).timestamp()
                    except (KeyError, ValueError, TypeError, AttributeError):
                        continue
                    if start - 5 <= created <= end + 5 and self.submission_id(row):
                        matches.append(row["id"])
            if len(matches) == 1:
                print(f"Recovered notary submission {matches[0]} from history.", file=sys.stderr)
                return matches[0]
            if attempt < 2:
                self.pause()
        return None

    def save(self, data):
        fd = os.open(self.response, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
            stream.write("\n")

    def notarize(self, file, no_acceleration=True):
        for attempt in range(2):
            start = time.time()
            flags = ["--no-s3-acceleration"] if no_acceleration or attempt else []
            code, data = self.command("submit", str(file), "--no-progress", "--no-wait", *flags)
            end = time.time()
            submission = self.submission_id(data)
            crashed = code in CRASHES
            if code != 0 or submission is None:
                submission = self.recover(file, start, end)
            if submission:
                self.ids.append(submission)
            if crashed:
                # A history row alone exists before the upload completes. Only a
                # terminal verdict proves this crashed upload reached analysis.
                recovered = None
                if submission:
                    for probe in range(3):
                        recovered = self.info(submission)
                        if recovered:
                            break
                        if probe < 2:
                            self.pause()
                if recovered and recovered["status"] in TERMINAL:
                    self.save(recovered)
                    return
                if attempt == 0:
                    print(f"Notary upload crashed with exit {code}; retrying once without S3 acceleration. "
                          f"Prior submission: {submission or 'unknown'}.", file=sys.stderr)
                    continue
                raise NotaryError("Notary upload crashed twice. Inspect private receipts and history; "
                                  f"no further retry. Submissions: {', '.join(self.ids) or 'unknown'}.")
            if submission is None:
                raise NotaryError(f"No unique upload found in notarytool history after exit {code}. "
                                  "Inspect receipts before any retry; no file was resubmitted.")
            failures = 0
            while True:
                data = self.info(submission)
                if data:
                    self.save(data)
                    failures = 0
                    if data["status"] in TERMINAL:
                        return
                else:
                    failures += 1
                    if failures >= 3:
                        raise NotaryError(f"Cannot read notary submission {submission} after three attempts; "
                                          "resume this ID without resubmitting.")
                self.pause()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    parser.add_argument("response", type=Path)
    parser.add_argument("--tool", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--no-s3-acceleration", choices=("0", "1"), default="1")
    args = parser.parse_args()
    if not math.isfinite(args.deadline):
        parser.error("deadline must be finite")
    try:
        Notarizer(args.tool, args.profile, args.deadline, args.response).notarize(
            args.file, args.no_s3_acceleration == "1")
    except (NotaryError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
