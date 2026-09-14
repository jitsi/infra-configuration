#!/usr/bin/env python3
"""
Check a rendered jibri xmpp.conf against what consul currently reports, or list
the hosts consul reports.

Why absolute rather than differential: consul-template can render xmpp.conf from a
transient catalog view that is missing a healthy shard, which silently disconnects
jibri from that shard. Diffing the new render against the previous file cannot
catch this reliably, because the file ansible writes and the file consul-template
writes describe the same hosts in different formats. So instead of asking "did this
render lose hosts", ask "does this render still cover every shard consul knows
about". That needs no history and works on the very first render.

Shard identity is "address:port", never the address alone: Nomad shards in the same
pool share a node IP and are told apart only by port, so a new shard can reuse a
retired shard's IP and two live shards can sit on one IP. The port comes from the
prosody_client_port service meta, defaulting to 5222 (it is NOT Service.Port, which
is 5280 for the signal service and 443 for all).

Grouping mirrors the scratch map in xmpp.conf.template: passing "signal" entries are
keyed by ServiceMeta.shard and passing "all" entries by ServiceMeta.domain, in that
order, set-if-absent (consul-template's MapSetX). The template renders one block per
key, so a key is satisfied when *any* of its hosts appears in the config; which one
the template picked is not predictable from a separate query.

Usage:
    check-jibri-xmpp-conf.py [--consul URL] [--timeout SECONDS] CONFIG
    check-jibri-xmpp-conf.py --list [--consul URL] [--timeout SECONDS]

Exit codes:
    0  config covers every key consul reports (or, with --list, listing succeeded)
    1  could not determine: consul unreachable, or the config could not be read
    2  config is missing at least one key consul reports; the missing keys and the
       hosts that would satisfy them are printed to stdout
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

DEFAULT_CONSUL = "http://127.0.0.1:8500"
DEFAULT_PORT = "5222"

# (consul service name, service meta key the template groups that service by)
SERVICE_KEYS = [("signal", "shard"), ("all", "domain")]

HOSTS_LINE = re.compile(r"xmpp-server-hosts")
QUOTED = re.compile(r'"([^"]+)"')


def normalize_consul_url(addr):
    """consul-template injects a scheme-less CONSUL_HTTP_ADDR (e.g. "127.0.0.1:8500")
    into the environment of the command it spawns, and urllib rejects that."""
    addr = addr.strip()
    if "://" not in addr:
        addr = "http://" + addr
    return addr.rstrip("/")


def service_host(entry):
    """The "address:port" this service entry renders as, mirroring the template's
    {{ .Address }}:{{ .ServiceMeta.prosody_client_port | default 5222 }}."""
    service = entry.get("Service") or {}
    node = entry.get("Node") or {}
    # consul-template's .Address falls back to the node address when the service
    # does not set one of its own
    address = service.get("Address") or node.get("Address")
    if not address:
        return None
    port = (service.get("Meta") or {}).get("prosody_client_port") or DEFAULT_PORT
    return "%s:%s" % (address, port)


def expected_hosts_by_key(consul_url, timeout):
    """Return {key: {"service": name, "hosts": set()}} for the passing services,
    grouped as the template groups them. Raises on a consul failure.

    A key claimed by an earlier service keeps only that service's hosts, because
    MapSetX is set-if-absent and signal is ranged over first. Within one service a
    key collects every host that could have claimed it, since consul's ordering is
    not predictable from a separate query and any of them satisfies the key.
    """
    by_key = {}
    for service_name, meta_key in SERVICE_KEYS:
        url = "%s/v1/health/service/%s?passing" % (consul_url, service_name)
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            entries = json.load(resp)
        for entry in entries:
            host = service_host(entry)
            if not host:
                continue
            meta = (entry.get("Service") or {}).get("Meta") or {}
            key = meta.get(meta_key) or ""
            claimed = by_key.get(key)
            if claimed is None:
                by_key[key] = {"service": service_name, "hosts": {host}}
            elif claimed["service"] == service_name:
                claimed["hosts"].add(host)
    return by_key


def hosts_in_config(path):
    """The "address:port" entries listed in a rendered xmpp.conf. Ports are kept
    verbatim; see the module docstring on why they must never be normalized away."""
    hosts = set()
    with open(path, "r") as handle:
        for line in handle:
            if HOSTS_LINE.search(line):
                hosts.update(QUOTED.findall(line))
    return hosts


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("config", nargs="?", help="rendered xmpp.conf to check")
    parser.add_argument("--list", action="store_true", dest="list_only",
                        help="print the hosts consul reports, one per line, instead of checking")
    parser.add_argument("--consul", default=DEFAULT_CONSUL,
                        help="consul HTTP address, scheme optional (default %(default)s)")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="per-request timeout in seconds (default %(default)s)")
    args = parser.parse_args()

    if not args.list_only and not args.config:
        parser.error("a config path is required unless --list is given")

    consul_url = normalize_consul_url(args.consul)
    try:
        by_key = expected_hosts_by_key(consul_url, args.timeout)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print("check-jibri-xmpp-conf: failed to query %s: %s" % (consul_url, exc), file=sys.stderr)
        return 1

    if args.list_only:
        every_host = set()
        for detail in by_key.values():
            every_host.update(detail["hosts"])
        for host in sorted(every_host):
            print(host)
        return 0

    try:
        present = hosts_in_config(args.config)
    except OSError as exc:
        print("check-jibri-xmpp-conf: failed to read %s: %s" % (args.config, exc), file=sys.stderr)
        return 1

    missing = {
        key: detail for key, detail in by_key.items()
        if not (detail["hosts"] & present)
    }
    if not missing:
        print("ok: %d of %d key(s) covered" % (len(by_key), len(by_key)))
        return 0

    for key in sorted(missing):
        detail = missing[key]
        print("missing %s %s: none of %s present" % (
            detail["service"], key or "(unnamed)", ", ".join(sorted(detail["hosts"]))))
    return 2


if __name__ == "__main__":
    sys.exit(main())
