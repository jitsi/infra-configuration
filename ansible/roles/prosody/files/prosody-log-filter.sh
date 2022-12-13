#!/bin/bash

[ -z "$PROSODY_FIFO" ] && PROSODY_FIFO="/var/log/prosody/prosody.fifo"
[ -z "$LOG_DIR" ] && LOG_DIR="/var/log/prosody-filtered"
[ -z "$LOG_OUTPUT" ] && LOG_OUTPUT="$LOG_DIR/prosody-filtered.log"

EGREP_PATTERN="c2s|epoll|[0-9] conn|runner|changed state from"
EXCLUDE_GREP_PATTERN="Missing listener 'ondrain'"

if [ ! -d "$LOG_DIR" ]; then
    mkdir "$LOG_DIR"
    touch "$LOG_OUTPUT"
fi

if [ ! -e "$PROSODY_FIFO" ]; then
    mkfifo "$PROSODY_FIFO"
    chown prosody:prosody "$PROSODY_FIFO"
fi

cat "$PROSODY_FIFO" | egrep "$EGREP_PATTERN" | grep -v "$EXCLUDE_GREP_PATTERN" >> "$LOG_OUTPUT"
