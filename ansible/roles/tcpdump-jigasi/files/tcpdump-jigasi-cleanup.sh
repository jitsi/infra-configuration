#!/bin/bash

/usr/bin/find /var/lib/tcpdump-jigasi -type f -mmin +300 -exec rm {} \;
