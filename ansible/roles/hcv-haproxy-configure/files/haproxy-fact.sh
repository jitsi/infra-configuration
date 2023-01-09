#!/bin/bash

FACT_CACHE_FILE="/tmp/haproxy-facts.json"
[ -f  "$FACT_CACHE_FILE" ] && cat $FACT_CACHE_FILE