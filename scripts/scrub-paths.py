#!/usr/bin/env python3
"""Takes this Mac's home folder out of an app bundle's binaries before it is published.

A Swift or C++ build keeps the absolute paths of its sources in __FILE__ strings and debug
information — `/Users/<you>/…/build/engine/SourcePackages/checkouts/mlx-swift/…` and the like.
The paths are harmless, but they name the person who built the binary and the account they were
built under.

    scripts/scrub-paths.py App.app            # replace, in place
    scripts/scrub-paths.py --check App.app    # report only, exit 1 when anything is found

The replacement keeps the byte length, so nothing in the binary moves: only the characters of the
paths change. Sign after scrubbing, never before — the signature covers these bytes.

The prefixes are worked out from this checkout's own location and from $HOME, so no account or
folder name is written down here; another machine's build is scrubbed the same way.
"""
import os
import sys

# The workspace that holds these checkouts (this script's repository's parent) and the account
# itself: the two spellings a built path can start with.
WORKSPACE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME = os.path.expanduser("~")
NEUTRAL_WORKSPACE = b"/build/agent/workspace/turbo-mlx-network"
# "/Users/" and as many placeholder letters as the account has: no account name is written down.
NEUTRAL_HOME = b"/Users/" + b"u" * max(0, len(os.fsencode(HOME)) - len(b"/Users/"))

# What a published build must never carry. Nothing here names any account: the release scripts set
# SCRUB_REFUSED (comma-separated) with the tokens of the certificate they sign with, or anything
# else they know must not ship.
REFUSED = [token.encode() for token in os.environ.get("SCRUB_REFUSED", "").split(",") if token]

MAX_BYTES = 512 << 20


def padded(neutral, target):
    """The neutral path at exactly the length of what it replaces: what is left is filled with
    slashes, which keeps a path looking like one."""
    if len(neutral) > len(target):
        raise SystemExit(f"{neutral!r} is longer than the path it replaces")
    return neutral + b"/" * (len(target) - len(neutral))


REPLACEMENTS = []
for prefix, neutral in ((WORKSPACE, NEUTRAL_WORKSPACE), (HOME, NEUTRAL_HOME)):
    raw = os.fsencode(prefix)
    REPLACEMENTS.append((raw, padded(neutral, raw)))


def files(root):
    if os.path.isfile(root):
        yield root
        return
    for folder, _, names in os.walk(root):
        for name in names:
            path = os.path.join(folder, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            yield path


def scrub(path, apply):
    """Replaces the prefixes and reports (path, replacements, refused) for one file."""
    size = os.path.getsize(path)
    if size == 0 or size > MAX_BYTES:
        return None
    with open(path, "rb") as handle:
        data = handle.read()
    refused = [token for token in REFUSED if token in data]
    count = 0
    for old, new in REPLACEMENTS:
        hits = data.count(old)
        if hits:
            count += hits
            if apply:
                data = data.replace(old, new)
    if apply and count:
        mode = os.stat(path).st_mode
        with open(path, "wb") as handle:
            handle.write(data)
        os.chmod(path, mode)
    if count or refused:
        return path, count, refused
    return None


def main(argv):
    apply = "--check" not in argv
    paths = [argument for argument in argv if not argument.startswith("--")]
    if not paths:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("usage: scrub-paths.py [--check] App.app", file=sys.stderr)
        return 2
    changed = 0
    refused = 0
    for root in paths:
        for path in sorted(files(root)):
            result = scrub(path, apply)
            if result is None:
                continue
            found, count, tokens = result
            changed += count
            if count:
                verb = "replaced" if apply else "found"
                print(f"{found}: {verb} {count} path{'s' if count != 1 else ''}")
            for token in tokens:
                refused += 1
                print(f"{found}: carries {token.decode(errors='replace')!r}", file=sys.stderr)
    if refused:
        print("remove these before publishing: they name a person", file=sys.stderr)
        return 1
    if not apply and changed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
