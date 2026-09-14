#!/usr/bin/env python3
"""
Print the XMPP "host:port" entries that consul currently considers healthy,
one per line, sorted. This mirrors what the jibri xmpp.conf.template renders:
the union of the passing "signal" and "all" services, using the
prosody_client_port service meta when present and 5222 otherwise.

Used by reconfigure-jibri-wrapper.sh to decide whether a rendered config that
drops hosts reflects a real shard removal or a transient consul view.

Usage:
    consul-passing-hosts.py [--consul URL] [--service NAME ...] [--timeout SECONDS]

Exit codes:
    0  success (an empty list is still a success)
    1  consul could not be queried
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

DEFAULT_CONSUL = "http://127.0.0.1:8500"
DEFAULT_SERVICES = ["signal", "all"]
DEFAULT_PORT = "5222"


def passing_hosts(consul_url, services, timeout):
    base = consul_url.rstrip("/")
    hosts = set()
    for svc in services:
        url = "%s/v1/health/service/%s?passing" % (base, svc)
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            for entry in json.load(resp):
                service = entry.get("Service") or {}
                addr = service.get("Address") or (entry.get("Node") or {}).get("Address")
                if not addr:
                    continue
                port = (service.get("Meta") or {}).get("prosody_client_port") or DEFAULT_PORT
                hosts.add("%s:%s" % (addr, port))
    return sorted(hosts)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--consul", default=DEFAULT_CONSUL, help="consul HTTP address (default %(default)s)")
    parser.add_argument(
        "--service",
        action="append",
        dest="services",
        help="service name to include; repeatable (default: %s)" % " ".join(DEFAULT_SERVICES),
    )
    parser.add_argument("--timeout", type=float, default=5.0, help="per-request timeout in seconds (default %(default)s)")
    args = parser.parse_args()

    try:
        hosts = passing_hosts(args.consul, args.services or DEFAULT_SERVICES, args.timeout)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print("consul-passing-hosts: failed to query %s: %s" % (args.consul, exc), file=sys.stderr)
        return 1

    for host in hosts:
        print(host)
    return 0


if __name__ == "__main__":
    sys.exit(main())
