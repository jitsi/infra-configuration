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
import subprocess
from datetime import datetime, date, time
from datadog import statsd

import time as ttime

stats_whitelist = [
    'bit_rate_download',
    'bit_rate_upload',
    'conferences',
    'dtls_failed_endpoints',
    'dtls_send_queue.dropped_packets',
    'dtls_send_queue.exceptions',
    'endpoints_disconnected',
    'endpoints_reconnected',
    'endpoints_sending_audio',
    'endpoints_sending_video',
    'endpoints_with_high_outgoing_loss',
    "endpoints_with_suspended_sources",
    'graceful_shutdown',
    'inactive_conferences',
    'inactive_endpoints',
    'incoming_loss',
    'jvm_gc.young_count',
    'jvm_gc.young_time',
    'jvm_gc.full_count',
    'jvm_gc.full_time',
    'jvm_gc.old_capacity',
    'jvm_gc.old_utilization',
    'largest_conference',
    'local_active_endpoints',
    'muc_clients_configured',
    'muc_clients_connected',
    'mucs_configured',
    'mucs_joined',
    'num_eps_no_msg_transport_after_delay',
    'num_eps_oversending',
    'num_relays_no_msg_transport_after_delay',
    'octo_conferences',
    'octo_endpoints',
    'octo_receive_bitrate',
    'octo_receive_packet_rate',
    'octo_receive_queue.dropped_packets',
    'octo_receive_queue.exceptions',
    'octo_send_bitrate',
    'octo_send_packet_rate',
    'octo_send_queue.dropped_packets',
    'octo_send_queue.exceptions',
    'outgoing_loss',
    'p2p_conferences',
    'packet_rate_download',
    'packet_rate_upload',
    'participants',
    'receive_only_endpoints',
    'rtp_receiver_queue.dropped_packets',
    'rtp_receiver_queue.exceptions',
    'rtp_sender_queue.dropped_packets',
    'rtp_sender_queue.exceptions',
    'rtt_aggregate',
    'srtp_send_queue.dropped_packets',
    'srtp_send_queue.exceptions',
    'stress_level',
    'threads',
    'total_colibri_web_socket_messages_received',
    'total_colibri_web_socket_messages_sent',
    'total_conference_seconds',
    'total_conferences_created',
    'total_data_channel_messages_sent',
    'total_data_channel_messages_received',
    'total_fds',
    'total_ice_failed',
    'total_ice_succeeded',
    'total_ice_succeeded_relayed',
    'total_packets_dropped_octo',
    'total_video_stream_milliseconds_received',
    'transit.rtp.all', # Legacy
    'transit.rtp.gt5ms',
    'transit.rtp.gt50ms',
    'transit.rtp.gt500ms',
    'transit.rtp.total',
    'visitors'
]

def get_jvb_pid(new_bridge):
    jvb_service = 'jitsi-videobridge2' if new_bridge else 'jitsi-videobridge'
    return int(subprocess.check_output('/bin/systemctl show -p MainPID %s | cut -d= -f2' % jvb_service, shell=True).strip())

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


def report_gauges(account_stats, environment, shard, prefix=None):
    if not prefix:
        prefix = 'jitsi'
    for stat in account_stats:
        if stat not in stats_whitelist:
            continue
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


current_milli_time = lambda: int(round(ttime.time() * 1000))

stats_url = 'http://localhost:8080/colibri/stats'
last_stats_file = '/tmp/jvb-stats-last.json'
stats_file = '/tmp/jvb-stats.json'
q_stats_url = 'http://localhost:8080/debug/stats/jvb/queue-stats'
last_q_stats_file = '/tmp/jvb-q-stats-last.json'
q_stats_file = '/tmp/jvb-q-stats.json'
pool_stats_url = 'http://localhost:8080/debug/stats/jvb/pool-stats'
transit_stats_url = 'http://localhost:8080/debug/stats/jvb/transit-stats'
last_transit_stats_file = '/tmp/jvb-transit-stats-last.json'

environment = os.environ['ENVIRONMENT']
shard = os.environ['SHARD']

prefix = 'jitsi.JVB'

last_jvb_stats = load_json_from_file(last_stats_file)
last_jvb_q_stats = load_json_from_file(last_q_stats_file)
last_jvb_transit_stats = load_json_from_file(last_transit_stats_file)

jvb_stats = load_json_from_url(stats_url, stats_file)
jvb_q_stats = load_json_from_url(q_stats_url, q_stats_file)
jvb_pool_stats = load_json_from_url(pool_stats_url)
jvb_transit_stats = load_json_from_url(transit_stats_url)


stats_to_ignore = ['current_timestamp', 'region', 'relay_id', 'version']
# build up the basic stats
report_stats = {}
for key in jvb_stats:
    if key == 'conference_sizes':
        # throw the conference sizes as individual separate stats
        conferences_by_size = jvb_stats[key]
        for csize, ccount in enumerate(conferences_by_size):
            report_stats['conference_count_%s' % csize] = ccount
    elif key in ['conferences_by_audio_senders', 'conferences_by_video_senders']:
        for index, count in enumerate(jvb_stats[key]):
            report_stats['%s_%s' % (key, index)] = count

    elif key in stats_to_ignore:
        pass
    elif (key == 'graceful_shutdown' or key == 'healthy'):
        if jvb_stats[key]:
            report_stats[key] = 1
        else:
            report_stats[key] = 0
    # by default, throw the stat
    else:
        report_stats[key] = jvb_stats[key]


# now build up averages and deltas from last stats
# make sure we're using the latest JVB, with at least total_conference_seconds
if jvb_stats and "total_conference_seconds" in jvb_stats:
    # The stats from the old and new bridge have slightly different formats. We support both
    # and recognize the new bridge by the existence of the total_participants stat.
    new_bridge = jvb_stats.get('total_participants') is not None

    if new_bridge:
        report_stats['total_participants'] = jvb_stats['total_participants']
    else:
        # total_participants is almost total_channels / 2. Jigasi only has an audio channel.
        report_stats['total_participants'] = jvb_stats['total_channels'] / 2

    jvb_pid = get_jvb_pid(new_bridge)
    append_gc_stats(report_stats, jvb_pid)
    report_stats['total_fds'] = fetch_fd_count(jvb_pid)

    totalParticipants = report_stats['total_participants']

    conferenceSeconds = jvb_stats["total_conference_seconds"]
    conferencesCompleted = jvb_stats["total_conferences_completed"]
    conferencesCreated = jvb_stats["total_conferences_created"]

    if conferencesCompleted > 0:
        report_stats['average_conference_seconds'] = conferenceSeconds/conferencesCompleted
    else:
        report_stats['average_conference_seconds'] = 0

    if last_jvb_stats and "total_conference_seconds" in last_jvb_stats:
        if new_bridge:
            last_jvb_stats['total_participants'] = last_jvb_stats['participants']
        else:
            last_jvb_stats['total_participants'] = last_jvb_stats['total_channels'] / 2

        lastTotalParticipants = last_jvb_stats['total_participants']
        lastConferenceSeconds = last_jvb_stats["total_conference_seconds"]
        lastConferencesCompleted = last_jvb_stats["total_conferences_completed"]
        lastConferencesCreated = last_jvb_stats["total_conferences_created"]

        report_stats['conference_completed_delta'] = conferencesCompleted - lastConferencesCompleted
        report_stats['conference_seconds_delta'] = conferenceSeconds - lastConferenceSeconds
        report_stats['conference_created_delta'] = conferencesCreated - lastConferencesCreated
        report_stats['total_participants_delta'] = totalParticipants - lastTotalParticipants

        # do a quick negative check for all deltas, in case of restart of JVB since history was written
        delta_keys = ['total_participants_delta', 'conference_completed_delta', 'conference_seconds_delta',
                      'conference_created_delta']
        for dk in delta_keys:
            if report_stats[dk] < 0:
                report_stats[dk] = 0

        if report_stats['conference_completed_delta'] > 0:
            report_stats['average_conference_seconds_delta'] = \
                report_stats['conference_seconds_delta'] / report_stats['conference_completed_delta']

# What we get from the bridge:
#   "dtls_send_queue": {
#     "dropped_packets": 1234,
#     "exceptions": 12
#   }
# What we report:
# jitsi.JVB.dtls_send_queue.dropped_packets = 1234 - previous
# jitsi.JVB.dtls_send_queue.exceptions = 12 - previous
# jitsi.JVB.dtls_send_queue.total_dropped_packets = 1234
# jitsi.JVB.dtls_send_queue.total_exceptions = 12
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

if jvb_pool_stats:
    for pool_stat in ['allocation_percent', 'num_large_requests', 'num_requests', 'num_returns', 'num_allocations', 'outstanding_buffers']:
        if pool_stat in jvb_pool_stats:
            report_stats['memory_pool.%s' % pool_stat] = jvb_pool_stats[pool_stat]

if jvb_transit_stats:
    if 'overall_bridge_jitter' in jvb_transit_stats:
        report_stats['transit.overall_bridge_jitter'] = jvb_transit_stats['overall_bridge_jitter']
    e2e_packet_delay = jvb_transit_stats['e2e_packet_delay']
    for protocol in ['rtp', 'rtcp']:
        report_stats['transit.%s.average_delay_ms' % protocol] = e2e_packet_delay[protocol]['average_delay_ms']
        report_stats['transit.%s.max_delay_ms' % protocol] = e2e_packet_delay[protocol]['max_delay_ms']
    if last_jvb_transit_stats:
        last_e2e_packet_delay = last_jvb_transit_stats['e2e_packet_delay']
        for protocol in ['rtp', 'rtcp']:
            total = e2e_packet_delay[protocol]['total_count']
            total_delta = total - last_e2e_packet_delay[protocol]['total_count']
            report_stats['transit.%s.total' % protocol] = total_delta
            buckets = e2e_packet_delay[protocol]['buckets']
            last_buckets = last_e2e_packet_delay[protocol]['buckets']

            if ('> 1000 ms' in buckets.keys()):
                # Legacy stats. Remove once jvb is updated eveywhere.
                gt1000ms = buckets['> 1000 ms'] - last_buckets['> 1000 ms']
                all = gt5ms = gt50ms = gt500ms = gt1000ms
                for ms in [2, 5, 20, 50, 200, 500, 1000]:
                    key = '<= %s ms' % ms
                    delta = max(0, buckets[key] - last_buckets[key])

                    # The buckets from jvb are exclusive ('<= 20 ms' includes packets delayed between 5 and 20 ms).
                    # We want to report inclusive (gt5ms is all packets delayed more than 5ms).
                    all += delta
                    if ms > 5:
                        gt5ms += delta
                    if ms > 50:
                        gt50ms += delta
                    if ms > 500:
                        gt500ms += delta

                # Do not report until the machine has processed some packets. Reduce noise after bootup.
                if (total > 50000):
                    report_stats['transit.%s.all' % protocol] = all
                    report_stats['transit.%s.gt5ms' % protocol] = gt5ms
                    report_stats['transit.%s.gt50ms' % protocol] = gt50ms
                    report_stats['transit.%s.gt500ms' % protocol] = gt500ms
            else:
                # Do not report until the machine has processed some packets. Reduce noise after bootup.
                if (total > 50000):
                    for ms in [5, 50, 500]:
                        jvb_key = '%s_to_max_ms' % ms
                        push_key = 'gt%sms' % ms

                        delta = max(0, buckets[jvb_key] - last_buckets[jvb_key])
                        report_stats['transit.%s.%s' % (protocol, push_key)] = delta


# finally report the stats
print("Reporting: %s" % json.dumps(report_stats, sort_keys=True, indent=4))
report_gauges(report_stats, environment, shard, prefix)

# write the recently gathered stats into previous file
if jvb_stats:
    with open(last_stats_file, 'w') as f:
        f.write(json.dumps(jvb_stats))
if jvb_q_stats:
    with open(last_q_stats_file, 'w') as f:
        f.write(json.dumps(jvb_q_stats))
if jvb_transit_stats:
    with open(last_transit_stats_file, 'w') as f:
        f.write(json.dumps(jvb_transit_stats))
