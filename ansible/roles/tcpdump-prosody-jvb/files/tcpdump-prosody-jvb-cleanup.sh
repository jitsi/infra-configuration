#!/bin/bash

/usr/bin/find /var/lib/tcpdump-prosody-jvb -type f -mmin +300 -exec rm {} \;
