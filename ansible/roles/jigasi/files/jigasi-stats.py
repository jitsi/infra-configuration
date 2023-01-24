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

# import urllib2
# import urllib
import argparse
import pprint
import json
import os
from datetime import datetime, date, time
from datadog import statsd

import time as ttime


def report_conference_size_histogram(conferences_by_sizes, environment, prefix=None):
    # report conference sizes as a histogram
    stat = 'conference_sizes'
    for csize, ccount in enumerate(conferences_by_size):
        # only count conferences of size 2 or greater in histogram
        if csize > 1:
            for i in range(0, ccount):
                statsd.histogram('%s.%s' % (prefix, stat), csize, tags=['environment:%s' % environment])


def report_gauges(account_stats, environment, prefix=None):
    if not prefix:
        prefix = 'jitsi'
    for stat in account_stats:
        statsd.gauge('%s.%s' % (prefix, stat), account_stats[stat], tags=['environment:%s' % environment])

    return True


current_milli_time = lambda: int(round(ttime.time() * 1000))

stats_url = 'http://localhost:8788/about/stats'
last_stats_file = '/tmp/jigasi-stats-last.json'
stats_file = '/tmp/jigasi-stats.json'

environment = os.environ['ENVIRONMENT']

prefix = 'jitsi.jigasi'

f = urlopen(stats_url)

try:
    with open(last_stats_file, 'r') as last_f:
        last_jigasi_stats = json.loads(last_f.read())
except IOError:
    last_jigasi_stats = None

jigasi_stats = json.loads(f.read())

with open(stats_file, 'w') as f:
    f.write(json.dumps(jigasi_stats))

# build up the basic stats
report_stats = {}
for key in jigasi_stats:
    if key == 'conference_sizes':
        # throw the conference sizes as individual separate stats
        conferences_by_size = jigasi_stats[key]
        for csize, ccount in enumerate(conferences_by_size):
            report_stats['conference_count_%s' % csize] = ccount

    elif key == 'current_timestamp':
        # for now do nothing with this
        pass
    elif key == 'graceful_shutdown':
        if jigasi_stats[key]:
            report_stats[key] = 1
        else:
            report_stats[key] = 0
    else:
        # by default, throw the stat
        report_stats[key] = jigasi_stats[key]

# now build up averages and deltas from last stats
# make sure we're using the latest jigasi, with at least total_conferences
if "total_conference_seconds" in jigasi_stats:
    # according to boris, total_participants is actually total_channels / 2
    totalParticipants = report_stats['total_participants']
    totalCallsWithDroppedMedia = report_stats['total_calls_with_dropped_media']
    report_stats['total_calls_with_dropped_media'] = totalCallsWithDroppedMedia

    conferenceSeconds = jigasi_stats["total_conference_seconds"]
    conferencesCompleted = jigasi_stats["total_conferences_completed"]

    if conferencesCompleted > 0:
        report_stats['average_conference_seconds'] = conferenceSeconds / conferencesCompleted
    else:
        report_stats['average_conference_seconds'] = 0

    if last_jigasi_stats and "total_conference_seconds" in last_jigasi_stats:
        #        last_jigasi_stats['total_participants'] = last_jigasi_stats['total_participants']
        lastTotalParticipants = last_jigasi_stats['total_participants']
        lastConferenceSeconds = last_jigasi_stats['total_conference_seconds']
        lastConferencesCompleted = last_jigasi_stats['total_conferences_completed']
        lastTotalCallsWithDroppedMedia = last_jigasi_stats['total_calls_with_dropped_media']

        report_stats['conference_completed_delta'] = conferencesCompleted - lastConferencesCompleted
        report_stats['conference_seconds_delta'] = conferenceSeconds - lastConferenceSeconds
        report_stats['total_participants_delta'] = totalParticipants - lastTotalParticipants
        report_stats['calls_with_dropped_media'] = totalCallsWithDroppedMedia - lastTotalCallsWithDroppedMedia

        # do a quick negative check for all deltas, in case of restart of JVB since history was written
        delta_keys = ['total_participants_delta',
                      'conference_completed_delta',
                      'conference_seconds_delta',
                      'calls_with_dropped_media']
        for dk in delta_keys:
            if report_stats[dk] < 0:
                report_stats[dk] = 0

        if report_stats['conference_completed_delta'] > 0:
            report_stats['average_conference_seconds_delta'] = report_stats['conference_seconds_delta'] / report_stats[
                'conference_completed_delta']

# finally report the stats
report_gauges(report_stats, environment, prefix)
# write out histograms for conference size distribution
report_conference_size_histogram(jigasi_stats['conference_sizes'], environment, prefix)

# write the recently gathered stats into previous file

with open(last_stats_file, 'w') as last_f:
    last_f.write(json.dumps(jigasi_stats))
