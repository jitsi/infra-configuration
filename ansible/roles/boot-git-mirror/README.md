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
2. `/opt/jitsi/boot/git-mirror-host`, which this role records from `ansible_env`
   during the first-boot ansible run, because reconfigures and later boots inherit
   nothing from user-data;
3. otherwise no mirror, github only.

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

The boot scripts are baked into images and re-copied on every reconfigure. The
script that clones the repos is itself replaced by a run that already cloned
them, so a change lands on an instance on the run after the one that ships it.
Instances that booted before this role existed never saw `GIT_MIRROR_HOST` in an
ansible run, so they have no recorded host and keep cloning from github until
they are replaced.
