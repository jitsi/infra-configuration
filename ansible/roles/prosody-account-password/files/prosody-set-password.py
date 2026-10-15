#!/usr/bin/env python3
# Set a prosody account password unless it provably matches the stored one.
#
# prosodyctl passwd always rewrites the credentials, even with the same password, and prosody
# then closes every session of that account with a "Password changed" stream error. On a live
# shard that kicks every jicofo, jibri, jigasi or jvb off and stops in-progress recordings.
#
# Usage: prosody-set-password [--config CFG] ACCOUNT_DAT_FILE USER@DOMAIN
# The password is read from stdin, one line only. Prints "changed" or "unchanged".
import argparse
import hashlib
import hmac
import re
import subprocess
import sys

# mod_auth_internal_hashed stores hex SCRAM keys; the length tells SHA-1 (default) from SHA-256.
HASHES_BY_HEX_LENGTH = {40: hashlib.sha1, 64: hashlib.sha256}


def stored_credentials(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        return None
    return dict(re.findall(r'\["(\w+)"\]\s*=\s*"?([^";]*)"?;', text))


def password_matches(password, creds):
    if not creds or not all(k in creds for k in ("salt", "iteration_count", "stored_key", "server_key")):
        return False
    # prosody SASLprep-normalizes the password first. That leaves printable ASCII as is, so any
    # other password skips the check and is rewritten.
    if not (password.isascii() and password.isprintable()):
        return False
    hasher = HASHES_BY_HEX_LENGTH.get(len(creds["stored_key"]))
    if hasher is None or not creds["iteration_count"].isdigit():
        return False
    salted = hashlib.pbkdf2_hmac(
        hasher().name, password.encode(), creds["salt"].encode(), int(creds["iteration_count"])
    )
    stored_key = hasher(hmac.new(salted, b"Client Key", hasher).digest()).hexdigest()
    server_key = hmac.new(salted, b"Server Key", hasher).hexdigest()
    return hmac.compare_digest(stored_key, creds["stored_key"]) and hmac.compare_digest(
        server_key, creds["server_key"]
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    parser.add_argument("account_file")
    parser.add_argument("jid")
    args = parser.parse_args()

    password = sys.stdin.read()
    if password.endswith("\n"):
        password = password[:-1]
    if not password:
        sys.exit("no password on stdin")
    # prosodyctl reads one line per prompt, so it would silently set only the first line.
    if "\n" in password:
        sys.exit("password on stdin has more than one line")

    if password_matches(password, stored_credentials(args.account_file)):
        print("unchanged")
        return

    cmd = ["prosodyctl"]
    if args.config:
        cmd += ["--config", args.config]
    cmd += ["passwd", args.jid]
    result = subprocess.run(cmd, input=f"{password}\n{password}\n", text=True, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        sys.exit(result.returncode)
    print("changed")


if __name__ == "__main__":
    main()
