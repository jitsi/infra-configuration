# boot-git-mirror

Installs `/opt/jitsi/boot/git-mirror-lib.sh`, the shared `checkout_repos` used by
every on-disk boot script (`/usr/local/bin/configure-*-local*.sh`), and records the
instance's boot-time `GIT_MIRROR_HOST` in `/opt/jitsi/boot/git-mirror-host`.
Tracking: JIT-16092.

## What the library does

`checkout_repos` clones `infra-configuration` and `infra-customizations` into
`$BOOTSTRAP_DIRECTORY` at `$GIT_BRANCH`, trying the in-region Gitea mirror
(`https://<env>-<region>-git.jitsi.net`) first and falling back to github on any
mirror failure. The mirror is an optimisation and github is the floor: the
function fails only when github fails too. The semantics are a copy of
infra-provisioning's `terraform/lib/postinstall-lib.sh`, the version inlined into
cloud-init user-data; keep the two in step.

Where `GIT_MIRROR_HOST` comes from on an instance, in order:

1. the environment, when the script is a child of the user-data that exported it
   (first boot);
2. `/opt/jitsi/boot/git-mirror-host`, written by infra-provisioning's user-data
   (`record_git_mirror_host` in `terraform/lib/postinstall-lib.sh`, called from
   `postinstall-footer.sh` so every stack passes through it whatever its
   `MAIN_COMMAND`);
3. otherwise no mirror, github only. An empty file is case 3, said explicitly, so
   a stack that opts back out stops using the mirror without an image rebuild.

Case 2 is the one that carries the feature. Reconfigures inherit nothing from
user-data, and the jvb and jibri postinstalls are invoked through `sudo`, which
resets the environment, so for those two roles case 1 never happens even on a
first boot. This role does not write the file: one writer, in the process that
actually has the variable.

`auto` derives the hostname from `ENVIRONMENT` and `ORACLE_REGION`, which the
`-oracle` scripts get from `/usr/local/bin/oracle_cache.sh`. The region gate
(mirrors exist only in an environment's `NOMAD_REGIONS`) is applied when the stack
is created in infra-provisioning, so a recorded `auto` only ever appears on an
instance in a region that has a mirror.

Only repos the mirror hosts get a mirror URL (`infra-configuration`,
`infra-customizations-private`, `infra-provisioning`). The scripts' default
customizations repo is the public `infra-customizations`, which is logged and
cloned from github rather than guessed at.

The read-only Gitea user for the private repo is read from `gitea-read-user` in
`jvb-bucket-<env>` on every run and handed to the one `git clone` of the mirror
host through that process's environment and a per-command credential helper. It
is never written to disk. A `/root/.netrc` breaks nomad's unprivileged artifact
getter, so a leftover one is removed on every run (infra-provisioning #1202).

## Log lines

Every decision logs exactly one line, so a quiet log cannot mean three things.
In `/var/log/postinstall-ansible.log` (where the boot scripts log) expect one of:

```
Using GIT_MIRROR_HOST=auto from the environment
Using GIT_MIRROR_HOST=auto from /opt/jitsi/boot/git-mirror-host
No GIT_MIRROR_HOST in the environment and no /opt/jitsi/boot/git-mirror-host; cloning from github
```

then `Using git mirror <host>`, a credentials line, and per repo either
`Cloned <repo> at <ref> from the in-region mirror` or
`WARNING: mirror clone of <repo> at <ref> failed, falling back to github` followed
by `Cloned <repo> at <ref> from github`.

## Rollout note

The boot scripts are baked into images, and which of them refresh without a
rebuild depends on where the copy task lives. The reconfigure playbooks all pass
`install_flag: false`:

| Role | Copy task in | Refreshes on reconfigure |
|---|---|---|
| jigasi | `install.yml` and `configure.yml` | yes |
| haproxy (oracle) | `main.yml`, no build gate | yes |
| selenium-grid | `main.yml`, ungated | yes, non-nomad grids |
| coturn, jibri, jicofo, jvb | `install.yml` only | no, needs an image rebuild |

The script that clones the repos is itself replaced by a run that already cloned
them, so even where it refreshes in place the change lands on the run after the
one that ships it. An instance that booted before infra-provisioning started
recording the host file has no file and keeps cloning from github until it is
replaced.
