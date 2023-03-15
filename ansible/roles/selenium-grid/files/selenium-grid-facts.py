#!/usr/bin/python
from __future__ import print_function

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
import logging
import sys
import traceback

GRID_NODE_ROLE = "node"
GRID_HUB_ROLE = "hub"
SHARD_SELENIUM_GRID_ROLE="selenium-grid"
SHARD_ROLE_TAG = "shard-role"
GRID_TAG = "grid"
GRID_ROLE_TAG = "grid-role"

CONSUL_REQUEST_TIMEOUT=5
AWS_REQUEST_TIMEOUT=5

local_data_path = "/etc/selenium-grid/environments.json"

aws_metadata_url = 'http://169.254.169.254/latest/dynamic/instance-identity/document'

def fact_from_service(service):
    grid = service['ServiceMeta']['grid']
    if 'ServiceTaggedAddresses' in service:
        if 'lan' in service['ServiceTaggedAddresses']:
            private_ip = service['ServiceTaggedAddresses']['lan']['Address']
        elif 'lan_ipv4' in service['ServiceTaggedAddresses']:
            private_ip = service['ServiceTaggedAddresses']['lan_ipv4']['Address']
        if 'wan' in service['ServiceTaggedAddresses']:
            public_ip = service['ServiceTaggedAddresses']['wan']['Address']
        elif 'wan_ipv4' in service['ServiceTaggedAddresses']:
            public_ip = service['ServiceTaggedAddresses']['wan_ipv4']['Address']
    else:
        private_ip = public_ip = service['Address']

    fact = {
        'grid': grid,
        'grid_hub_private_ip_address': private_ip,
        'grid_hub_public_ip_address': public_ip
    }

    return fact

def extract_tag(tags, tag_name):
        found_tag = False
        if tags:
            for t in tags:
                    if t['Key'] == tag_name:
                        return t['Value']
            if not found_tag:
                return ''
        else:
            return ''

def main():

    local_data = {}
    try:
        with open(local_data_path,'r') as f:
            local_data = json.loads(f.read())
    except Exception as e:
        #error happened
        print("Error loading local data file for jibri configuration local facts %s"%e,file = sys.stderr)
        exit(2)

    if 'consul_server' in local_data:

        consul_server = local_data['consul_server']
        local_grid = local_data['grid']
        local_role = local_data['grid_role']

        consul_service = 'selenium-grid-hub'
        hub_fact = False
        # disable cross-connecting of shards, only connect to local shard
        url='%s/v1/catalog/service/%s'%(consul_server,consul_service)
        data=urlencode({'filter':'ServiceMeta.grid == "%s"'%(local_grid)})
        response=None
        try:
            response = urlopen(url+'?'+data, timeout=CONSUL_REQUEST_TIMEOUT)
        except Exception as e:
            einfo = sys.exc_info()
            print('URL Open error %s?%s: %s'%(url,data,einfo[0]), file=sys.stderr)
            traceback.print_tb(einfo[2], file=sys.stderr)

        if response:
            results = json.loads(response.read())
            for service in results:
                hub_fact=fact_from_service(service)

        if hub_fact:
            facts = hub_fact
            facts['grid_role'] = local_role
        else:
            facts = {'grid_role':local_role,'grid':local_grid, 'address':'localhost','grid_hub_private_ip_address':'localhost', 'grid_hub_public_ip_address':'localhost'}

    else:
        aws_metadata = json.loads(urlopen(aws_metadata_url, timeout=AWS_REQUEST_TIMEOUT).read())
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
            else:
                facts = {'grid_role':local_role,'grid':local_grid, 'address':'localhost','grid_hub_private_ip_address':'localhost', 'grid_hub_public_ip_address':'localhost'}

    print(json.dumps(facts))

    #now read the server states from haproxy
    # server_states = read_haproxy_server_states()
    # print(server_states)


if __name__ == '__main__':
    main()
