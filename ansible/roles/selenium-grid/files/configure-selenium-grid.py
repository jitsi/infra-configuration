#!/usr/bin/python


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
import shutil
import json
import os
import boto3
import re


GRID_NODE_ROLE = "node"
GRID_HUB_ROLE = "hub"
SHARD_SELENIUM_GRID_ROLE="selenium-grid"
SHARD_ROLE_TAG = "shard-role"
GRID_TAG = "grid"
GRID_ROLE_TAG = "grid-role"

aws_metadata_url = 'http://169.254.169.254/latest/dynamic/instance-identity/document'
aws_public_ipv4_url = 'http://169.254.169.254/latest/meta-data/public-ipv4'

def main():


    aws_metadata = json.loads(urlopen(aws_metadata_url).read())
    instance_id = aws_metadata['instanceId']
    local_region = aws_metadata['region']

    ec2 = boto3.resource('ec2', region_name=local_region)
    local_instance = ec2.Instance(instance_id)
    tags = dict([(x['Key'], x['Value']) for x in local_instance.tags or []])
    local_grid = tags.get(GRID_TAG)
    local_role = tags.get(GRID_ROLE_TAG)

    if local_role:
        filters = [
                {'Name': 'instance-state-name', 'Values': ['running']},
                {'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': [SHARD_SELENIUM_GRID_ROLE]},
                {'Name': 'tag:' + GRID_ROLE_TAG, 'Values': [GRID_HUB_ROLE]},
                {'Name': 'tag:'+ GRID_TAG, 'Values':[local_grid]}
            ]

        instances = ec2.instances.filter(Filters=filters)
        if instances:
            for hub_host in instances:
                facts = {
                    'grid': local_grid,
                    'grid_role': local_role,
                    'grid_hub_private_ip_address': hub_host.private_ip_address,
                    'grid_hub_public_ip_address': hub_host.public_ip_address
                }

    print(json.dumps(facts))

    #now read the server states from haproxy
    # server_states = read_haproxy_server_states()
    # print(server_states)


if __name__ == '__main__':
    main()
