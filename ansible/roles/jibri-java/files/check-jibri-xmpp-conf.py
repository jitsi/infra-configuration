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

The check is per host, and a host is "address:port" -- never the address alone.
Nomad shards in the same pool share a node IP and are told apart only by port, so
a new shard can reuse a retired shard's IP and two live shards can sit on one IP.
Normalizing the port away would hide the loss of a co-located shard, which is
precisely what this guards against. The port comes from the prosody_client_port
service meta, defaulting to 5222; it is NOT Service.Port, which is 5280 for the
signal service and 443 for all.

Every passing host must appear in the config. That is exactly what
xmpp.conf.template renders: one environment block per domain listing every passing
host for that domain. (It used to keep only the first host per domain, so this
check had to be satisfied per domain rather than per shard, and could not see a
co-domain shard go missing. Both halves were fixed together.)

Hosts present in the config but no longer in consul are not reported. A shard that
has legitimately left is not a reason to reject a render.

When the config also joins the JVB brewery prosody (prosody-jvb), every passing
host must appear a second time, as "address:port" with the port taken from the
prosody_jvb_client_port service meta, defaulting to 6222. The config says whether
it does: any control-muc on a muc.jvb. domain turns this on. Deciding from the
file rather than from a flag keeps the consul-template hook and the reconcile cron
job, which run with different environments, in agreement.

Usage:
    check-jibri-xmpp-conf.py [--consul URL] [--timeout SECONDS] CONFIG
    check-jibri-xmpp-conf.py --list [--jvb-brewery] [--consul URL] [--timeout SECONDS]

Exit codes:
    0  config covers every host consul reports (or, with --list, listing succeeded)
    1  could not determine: consul unreachable, or the config could not be read
    2  config is missing at least one host consul reports; the missing hosts are
       printed to stdout, with the shard each one belongs to
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

DEFAULT_CONSUL = "http://127.0.0.1:8500"
DEFAULT_PORT = "5222"
DEFAULT_JVB_BREWERY_PORT = "6222"

SERVICES = ["signal", "all"]

HOSTS_LINE = re.compile(r"xmpp-server-hosts")
QUOTED = re.compile(r'"([^"]+)"')
JVB_BREWERY_MUC_LINE = re.compile(r'domain\s*=\s*"muc\.jvb\.')


def normalize_consul_url(addr):
    """consul-template injects a scheme-less CONSUL_HTTP_ADDR (e.g. "127.0.0.1:8500")
    into the environment of the command it spawns, and urllib rejects that."""
    addr = addr.strip()
    if "://" not in addr:
        addr = "http://" + addr
    return addr.rstrip("/")


def service_host(entry, port_meta="prosody_client_port", default_port=DEFAULT_PORT):
    """The "address:port" this service entry renders as, mirroring the template's
    {{ .Address }}:{{ or .ServiceMeta.prosody_client_port "5222" }} (or, for the JVB
    brewery block, prosody_jvb_client_port and 6222)."""
    service = entry.get("Service") or {}
    node = entry.get("Node") or {}
    # consul-template's .Address falls back to the node address when the service
    # does not set one of its own
    address = service.get("Address") or node.get("Address")
    if not address:
        return None
    port = (service.get("Meta") or {}).get(port_meta) or default_port
    return "%s:%s" % (address, port)


def passing_hosts(consul_url, timeout, jvb_brewery=False):
    """Return {host: label} for every passing service entry, where label names the
    shard and domain the host belongs to, for use in error output. With jvb_brewery,
    each entry's JVB brewery host is expected as well. Raises on a consul failure."""
    hosts = {}
    for service_name in SERVICES:
        url = "%s/v1/health/service/%s?passing" % (consul_url, service_name)
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            entries = json.load(resp)
        for entry in entries:
            host = service_host(entry)
            if not host:
                continue
            meta = (entry.get("Service") or {}).get("Meta") or {}
            label = "%s shard=%s domain=%s" % (
                service_name, meta.get("shard") or "?", meta.get("domain") or "?")
            hosts.setdefault(host, label)
            if jvb_brewery:
                jvb_host = service_host(entry, "prosody_jvb_client_port", DEFAULT_JVB_BREWERY_PORT)
                hosts.setdefault(jvb_host, label + " jvb-brewery")
    return hosts


def hosts_in_config(path):
    """The "address:port" entries listed in a rendered xmpp.conf. Ports are kept
    verbatim; see the module docstring on why they must never be normalized away."""
    hosts = set()
    with open(path, "r") as handle:
        for line in handle:
            if HOSTS_LINE.search(line):
                hosts.update(QUOTED.findall(line))
    return hosts


def joins_jvb_brewery(path):
    """Whether a rendered xmpp.conf has a control-muc on the JVB brewery prosody."""
    with open(path, "r") as handle:
        return any(JVB_BREWERY_MUC_LINE.search(line) for line in handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("config", nargs="?", help="rendered xmpp.conf to check")
    parser.add_argument("--list", action="store_true", dest="list_only",
                        help="print the hosts consul reports, one per line, instead of checking")
    parser.add_argument("--jvb-brewery", action="store_true",
                        help="with --list, also print each host's JVB brewery entry (a check works this "
                             "out from the config)")
    parser.add_argument("--consul", default=DEFAULT_CONSUL,
                        help="consul HTTP address, scheme optional (default %(default)s)")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="per-request timeout in seconds (default %(default)s)")
    args = parser.parse_args()

    if not args.list_only and not args.config:
        parser.error("a config path is required unless --list is given")

    jvb_brewery = args.jvb_brewery
    if not args.list_only:
        try:
            jvb_brewery = joins_jvb_brewery(args.config)
        except OSError as exc:
            print("check-jibri-xmpp-conf: failed to read %s: %s" % (args.config, exc), file=sys.stderr)
            return 1

    consul_url = normalize_consul_url(args.consul)
    try:
        expected = passing_hosts(consul_url, args.timeout, jvb_brewery)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print("check-jibri-xmpp-conf: failed to query %s: %s" % (consul_url, exc), file=sys.stderr)
        return 1

    if args.list_only:
        for host in sorted(expected):
            print(host)
        return 0

    try:
        present = hosts_in_config(args.config)
    except OSError as exc:
        print("check-jibri-xmpp-conf: failed to read %s: %s" % (args.config, exc), file=sys.stderr)
        return 1

    missing = sorted(host for host in expected if host not in present)
    if not missing:
        print("ok: %d of %d host(s) present" % (len(expected), len(expected)))
        return 0

    for host in missing:
        print("missing %s (%s)" % (host, expected[host]))
    return 2


if __name__ == "__main__":
    sys.exit(main())
