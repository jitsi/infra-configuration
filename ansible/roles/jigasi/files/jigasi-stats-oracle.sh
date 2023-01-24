#!/bin/bash

#pull our own instance and environment
. /usr/local/bin/oracle_cache.sh

#now run the python that pushes stats to statsd
/usr/local/bin/jigasi-stats.py
