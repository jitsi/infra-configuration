#!/usr/bin/env python

try:
    # For Python 3.0 and later
    from urllib.request import urlopen
except ImportError:
    # Fall back to Python 2's urllib2
    from urllib2 import urlopen

import pprint
import json
import os
import subprocess
from datadog import statsd

# This is a stripped-down version of jvb-stats.py which doesn't include the metrics with native prometheus support.
# It collects and reports additional metrics: garbage collection, queue, FD count


stats_whitelist = [
    'jvm_gc.young_count',
    'jvm_gc.young_time',
    'jvm_gc.full_count',
    'jvm_gc.full_time',
    'jvm_gc.old_capacity',
    'jvm_gc.old_utilization',
    'rtp_receiver_queue.dropped_packets',
    'rtp_receiver_queue.exceptions',
    'rtp_sender_queue.dropped_packets',
    'rtp_sender_queue.exceptions',
    'srtp_send_queue.dropped_packets',
    'srtp_send_queue.exceptions',
    'total_fds'
]

def get_jvb_pid():
    return int(subprocess.check_output('/bin/systemctl show -p MainPID jitsi-videobridge2 | cut -d= -f2', shell=True).strip())

def fetch_fd_count(pid):
    count = '0'
    try:
        count = subprocess.check_output('ls -1 /proc/%s/fd/ | wc -l' % pid, shell=True)
    except Exception as e:
        print("Failed to load open fd count: {}".format(e))

    return int(count.strip())

def append_gc_stats(report_stats, pid):
    jstat_stats = {
        'OC': 'jvm_gc.old_capacity',
        'OU': 'jvm_gc.old_utilization',
        'YGC': 'jvm_gc.young_count',
        'YGCT': 'jvm_gc.young_time',
        'FGC': 'jvm_gc.full_count',
        'FGCT': 'jvm_gc.full_time'
    }

    # "universal_newlines" is more clearly named "text" in newer Python, but this
    # keeps compatibility with older Python (including Python 2).
    jstat = subprocess.check_output(['jstat', '-gc', str(pid)], universal_newlines=True).splitlines()
    jstat_values = jstat[1].split()

    for index, field in enumerate(jstat[0].split()):
        if field in jstat_stats:
            try:
                value=jstat_values[index]
                # Verify that the value is numeric - jstat reports some fields as '-' for some garbage collectors
                float(value)
                report_stats[jstat_stats[field]] = value
            except ValueError:
                pass


def report_gauges(account_stats, environment, shard, prefix):
    for stat in account_stats:
        statsd.gauge('%s.%s' % (prefix, stat), account_stats[stat], tags=['environment:%s' % environment, 'shard:%s' % shard])

    return True

def load_json_from_file(filename):
    try:
        with open(filename, 'r') as f:
            return json.loads(f.read())
    except:
        return None

# Reads JSON from a URL and optionally writes it to a file
def load_json_from_url(url, filename=None):
    try:
        j = json.loads(urlopen(url).read())
        if filename:
            with open(filename, 'w') as f:
                f.write(json.dumps(j))
        return j
    except:
        return None


q_stats_url = 'http://localhost:8080/debug/stats/jvb/queue-stats'
last_q_stats_file = '/tmp/jvb-q-stats-last.json'
q_stats_file = '/tmp/jvb-q-stats.json'

environment = os.environ['ENVIRONMENT']
shard = os.environ['SHARD']

last_jvb_q_stats = load_json_from_file(last_q_stats_file)
jvb_q_stats = load_json_from_url(q_stats_url, q_stats_file)

# build up the basic stats
report_stats = {}

jvb_pid = get_jvb_pid()
append_gc_stats(report_stats, jvb_pid)
report_stats['total_fds'] = fetch_fd_count(jvb_pid)

# What we get from the bridge:
#   "rtp_receiver_send_queue": {
#     "dropped_packets": 1234,
#     "exceptions": 12
#   }
# What we report:
# jitsi.JVB.rtp_receiver_send_queue.dropped_packets = 1234 - previous
# jitsi.JVB.rtp_receiver_send_queue.exceptions = 12 - previous
# jitsi.JVB.rtp_receiver_send_queue.total_dropped_packets = 1234
# jitsi.JVB.rtp_receiver_send_queue.total_exceptions = 12
if jvb_q_stats:
    for q_name in jvb_q_stats:
        try:
            for q_stat in jvb_q_stats[q_name]:
                if type(jvb_q_stats[q_name][q_stat]) != int:
                    continue
                last = 0
                if last_jvb_q_stats and q_name in last_jvb_q_stats and q_stat in last_jvb_q_stats[q_name]:
                    last = last_jvb_q_stats[q_name][q_stat]

                    current = jvb_q_stats[q_name][q_stat]
                    delta = max(current - last, 0)
                    report_stats['%s.%s' % (q_name, q_stat)] = delta
                    report_stats['%s.total_%s' % (q_name, q_stat)] = current
        except TypeError: # stat was not iterable, probably null?
            continue

# finally report the stats

filtered = { key: value for key, value in report_stats.items() if key in stats_whitelist }
print("Reporting: %s" % json.dumps(filtered, sort_keys=True, indent=4))
report_gauges(filtered, environment, shard, 'jitsi.JVB')

# write the recently gathered stats into previous file
if jvb_q_stats:
    with open(last_q_stats_file, 'w') as f:
        f.write(json.dumps(jvb_q_stats))
