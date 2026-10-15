#!/usr/bin/python3
# Set a prosody account password unless it provably matches the stored one.
#
# prosodyctl passwd always rewrites the credentials, even with the same password, and prosody
# then closes every session of that account with a "Password changed" stream error. On a live
# shard that kicks every jicofo, jibri, jigasi or jvb off and stops in-progress recordings.
#
# This is a module, not a command, so that only the password is hidden from logs: no_log on the
# password argument masks it in the target's syslog and scrubs it from the returned output.

DOCUMENTATION = r"""
module: prosody_account_password
short_description: Set a prosody account password without rewriting an unchanged one
options:
  jid:
    description: Account JID, user@domain.
    required: true
    type: str
  account_file:
    description: The account's .dat file under the prosody data_path.
    required: true
    type: path
  password:
    description: The password to set.
    required: true
    type: str
  config:
    description: prosody.cfg.lua to pass to prosodyctl --config, for a second prosody instance.
    type: path
"""

import hashlib
import hmac
import re

from ansible.module_utils.basic import AnsibleModule

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
    module = AnsibleModule(
        argument_spec=dict(
            jid=dict(type="str", required=True),
            account_file=dict(type="path", required=True),
            password=dict(type="str", required=True, no_log=True),
            config=dict(type="path"),
        ),
        supports_check_mode=True,
    )
    jid = module.params["jid"]
    account_file = module.params["account_file"]
    password = module.params["password"]
    result = dict(changed=False, jid=jid, account_file=account_file)

    if not password:
        module.fail_json(msg="password is empty", **result)
    # prosodyctl reads one line per prompt, so it would silently set only the first line.
    if "\n" in password:
        module.fail_json(msg="password has more than one line", **result)

    if password_matches(password, stored_credentials(account_file)):
        module.exit_json(**result)

    result["changed"] = True
    if module.check_mode:
        module.exit_json(**result)

    cmd = ["prosodyctl"]
    if module.params["config"]:
        cmd += ["--config", module.params["config"]]
    cmd += ["passwd", jid]
    rc, stdout, stderr = module.run_command(cmd, data=f"{password}\n{password}")
    if rc != 0:
        module.fail_json(
            msg="prosodyctl passwd failed", rc=rc, stdout=stdout, stderr=stderr, jid=jid, account_file=account_file
        )
    module.exit_json(**result)


if __name__ == "__main__":
    main()
