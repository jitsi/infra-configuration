#!/usr/bin/env python

try:
    # For Python 3.0 and later
    from urllib.request import urlopen, build_opener, HTTPCookieProcessor
except ImportError:
    # Fall back to Python 2's urllib2
    from urllib2 import urlopen, build_opener, HTTPCookieProcessor


try:
    # For Python 3.0 and later
    from urllib.parse import urlencode
except ImportError:
    # Fall back to Python 2's urllib
    from urllib import urlencode


#import urllib2
#import urllib
import argparse
import pprint
import json
import os
import sys
import subprocess
from datetime import datetime, date, time
from datadog import statsd

import time as ttime


stats_url = 'http://localhost:8888/stats'
stats_file = '/tmp/jicofo-stats.json'

signal_sidecar_url = 'http://localhost:6000/signal/report'
signal_sidecar_file = '/tmp/jicofo-stats-sidecar-report.json'

def fetch_fd_count():
    count = '0'
    try:
        count = subprocess.check_output('ls -1 /proc/$(cat /var/run/jicofo.pid)/fd/ | wc -l', shell=True)
    except Exception as e:
        print("Failed to load open fd count: {}".format(e))

    return int(count.strip())


def report_gauges(account_stats, environment, shard, prefix=None, shard_state='drain'):
    if not prefix:
        prefix = 'jitsi'
    for stat in account_stats:
        statsd.gauge('%s.%s' % (prefix, stat), account_stats[stat], tags=['environment:%s' % environment, 'shard:%s' % shard, 'shard-state:%s' % shard_state])

    return True


# Reads JSON from a URL and optionally writes it to a file
def load_json_from_url(url, filename=None):
    try:
        j = json.loads(urlopen(url).read())
        if filename:
            with open(filename, 'w') as f:
                f.write(json.dumps(j))
        return j
    except:
        print("Unexpected error load json from url: {} error: {}".format(url, sys.exc_info()[0]))
        return None

# Flattens 'obj' into 'acc'. Only extracts int and float (ignores strings, booleans, and arrays).
def flatten(obj, acc, prefix=""):
    for key in obj:
        value = obj[key]
        if isinstance(value, (int, float)):
            acc["%s.%s" % (prefix, key)] = value
        elif isinstance(value, dict):
            flatten(value, acc, "%s.%s" % (prefix, key))


current_milli_time = lambda: int(round(ttime.time() * 1000))

environment = os.environ['ENVIRONMENT']
shard = os.environ['SHARD']

prefix = 'jitsi.jicofo'
shard_state = 'drain'

sidecar_report = load_json_from_url(signal_sidecar_url, signal_sidecar_file)
if sidecar_report:
    if 'services' in sidecar_report and 'statusFileContents' in sidecar_report['services'] and sidecar_report['services']['statusFileContents']:
        shard_state = sidecar_report['services']['statusFileContents']
else:
    print('Failed to load optional sidecar report from url {}, shard state will be reported as drain'.format(signal_sidecar_url))

jicofo_stats = load_json_from_url(stats_url, stats_file)

if jicofo_stats:

    stats_to_ignore = ['current_timestamp', 'region', 'relay_id', 'conference_sizes']
    # build up the basic stats
    report_stats = {}
    for key in jicofo_stats:
        if key == 'healthy':
            if jicofo_stats[key]:
                report_stats[key] = 1
            else:
                report_stats[key] = 0
        # The stats under 'focus' have a hierarchical structure.
        # Convert it to a flat list for datadog.
        elif key in stats_to_ignore:
            pass
        elif isinstance(jicofo_stats[key], dict):
            flatten(jicofo_stats[key], report_stats, key)
        # by default, throw the stat
        else:
            report_stats[key] = jicofo_stats[key]

    report_stats['total_fds'] = fetch_fd_count()

    # finally report the stats
    report_gauges(report_stats, environment, shard, prefix, shard_state)
else:
    print('Failed to load jicofo stats from url {}'.format(stats_url))
