# wavefront (telegraf)

Installs and configures telegraf on the VM fleet. telegraf exposes what it
collects for prometheus on `:9126` (`templates/20-prometheus.conf.j2`).

The role was copied from wavefrontHQ's ansible role and keeps its name, but it
no longer installs the wavefront proxy or writes to one.

- `wavefront_install_collector`: add the InfluxData apt repo, install telegraf
  at `wavefront_collector_version` and remove the repo again (image builds).
- `wavefront_configure_collector`: render `telegraf.conf` from
  `templates/telegraf.conf.wfcopy.j2` with `telegraf_inputs` and
  `telegraf_tags` (boot).

Both paths also remove `telegraf.d/10-wavefront.conf`, the wavefront output
that hosts and images configured before #910 still carry.
