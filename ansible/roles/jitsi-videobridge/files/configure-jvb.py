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
import time
import base64

SHARD_CORE_ROLE = "core"
SHARD_HAPROXY_ROLE = "haproxy"
ENVIRONMENT_TAG = "environment"
XMPP_DOMAIN_TAG = "domain"
PUBLIC_DOMAIN_TAG = "public_domain"
SHARD_TAG = "shard"
SHARD_ROLE_TAG = "shard-role"
SHARD_STATE_TAG = "shard-state"
SHARD_AGE_TAG = "shard-age"
RELEASE_NUMBER_TAG = "release_number"

CONSUL_REQUEST_TIMEOUT=5
AWS_REQUEST_TIMEOUT=5
RETRY_SLEEP=1

urls_by_datacenter = {}

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

# Reads JSON from a URL and optionally writes it to a file
def json_from_url(url, timeout, retries=3):
    global RETRY_SLEEP
    for i in range(0,retries):
        try:
            j = json.loads(urlopen(url,None,timeout=timeout).read())
            return j
        except:
            einfo = sys.exc_info()
            eprint("Unexpected error load from url {}:".format(url), einfo[0])
            traceback.print_tb(einfo[2], file=sys.stderr)
            time.sleep(RETRY_SLEEP)
            continue

    eprint("Failed retrying {} times for url {}:".format(retries, url), sys.exc_info()[0])
    return None

local_data_path = "/etc/jitsi/videobridge/environments.json"

aws_metadata_url = 'http://169.254.169.254/latest/dynamic/instance-identity/document'
aws_public_ipv4_url = 'http://169.254.169.254/latest/meta-data/public-ipv4'

def fact_from_service(service, dc):
    environment = service['ServiceMeta']['environment']
    domain = service['ServiceMeta']['domain']
    if 'shard' in service['ServiceMeta']:
        shard = service['ServiceMeta']['shard']
    else:
        shard = ''
    if 'ServiceTaggedAddresses' in service:
        private_ip = service['ServiceTaggedAddresses']['lan']['Address']
        public_ip = service['ServiceTaggedAddresses']['wan']['Address']
    else:
        private_ip = public_ip = service['Address']

    prefer_private = False
    if dc.startswith(environment):
        prefer_private = True;

    fact = {
        'environment': environment,
        'shard': shard,
        'xmpp_domain': domain,
        'xmpp_host_private_ip_address': private_ip,
        'xmpp_host_public_ip_address': public_ip,
        'id': shard,
        'address': public_ip,
        'prefer_private': prefer_private
    }

    if not fact['id']:
        fact['id'] = service['Node']

    return fact

def fact_from_instance(instance, local_data=None):
    environment = extract_tag(instance.tags,ENVIRONMENT_TAG)
    shard = extract_tag(instance.tags,SHARD_TAG)

    fact = {
        'environment': environment,
        'shard': shard,
        'xmpp_domain': extract_tag(instance.tags,XMPP_DOMAIN_TAG),
        'xmpp_host_private_ip_address': instance.private_ip_address,
        'xmpp_host_public_ip_address': instance.public_ip_address,
        'id': extract_tag(instance.tags,SHARD_TAG),
        'address': instance.public_ip_address
    }

    if not fact['id']:
        fact['id'] = extract_tag(instance.tags,NAME_TAG);

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

def fetch_datacenters(consul_url):
    global urls_by_datacenter

    url='%s/v1/catalog/datacenters'%consul_url
    results = json_from_url(url, timeout=CONSUL_REQUEST_TIMEOUT)
    if results:
        for r in results:
            urls_by_datacenter[r] = consul_url

        return results
    else:
        return []

def fetch_pool_state(consul_url, datacenter, environment, pool):
    shard_key='pool-states/%s/%s'%(environment,pool)
    url='%s/v1/kv/%s'%(consul_url,shard_key)
    data=urlencode({'dc':datacenter})
    try:
        results = json.loads(urlopen(url+'?'+data,None,timeout=CONSUL_REQUEST_TIMEOUT).read())
        if results and results[0]["Value"]:
            return base64.b64decode(results[0]["Value"]).decode('ascii')
        else:
            return None
    except:
        # skip it
        # einfo = sys.exc_info()
        # eprint("Failed loading key/value from url {}:".format(url), einfo[0])
        # traceback.print_tb(einfo[2], file=sys.stderr)

        return None

def main():
    global urls_by_datacenter

    default_address = 'localhost'
    local_data = {}
    try:
        with open(local_data_path,'r') as f:
            local_data = json.loads(f.read())
    except Exception as e:
        #error happened
        print("Error loading local data file for jvb configuration local facts %s"%e,file = sys.stderr)
        exit(2)

    if not 'regions' in local_data or not local_data['regions']:
        local_data['regions'] = []
    local_data['regions'] = [_f for _f in local_data['regions'] if _f]

    if 'consul_server' in local_data and local_data['consul_server']:
        consul_urls= ['https://%s'%local_data['consul_server']]

        if 'consul_extra_urls' in local_data:
            consul_urls.extend(local_data['consul_extra_urls'])

        if 'XMPP_HOST_PUBLIC_IP_ADDRESS' in os.environ:
            default_address = os.environ.get('XMPP_HOST_PUBLIC_IP_ADDRESS')

        datacenters = []
        local_datacenters = []
        for consul_url in consul_urls:
            segment_dcs = fetch_datacenters(consul_url)
            if segment_dcs:
                datacenters.extend(segment_dcs)
                # mark the first DC in each list as 'local'
                local_datacenters.append(segment_dcs[0])

        local_environment = local_data['environment']
        local_domain = local_data['domain']

        if 'shard' in local_data:
            local_shard = local_data['shard']
        else:
            local_shard='standalone'

        if 'release_number' in local_data:
            local_release_number = local_data['release_number']
        else:
            local_release_number=''


        pool_mode = 'shard'
        if 'pool_mode' in local_data:
            pool_mode = local_data['pool_mode']

        if pool_mode == 'shard':
            # support cross-region mode via global pool mode, mimics default behavior before pool_mode
            if 'enable_cross_region' in local_data and local_data['enable_cross_region']:
                pool_mode = 'global'

        # by default search for all shard in environment and release
        search_filter = 'ServiceMeta.environment == "%s" and ServiceMeta.release_number == "%s"'%(local_environment, local_release_number)
        if pool_mode == 'shard':
            # restrict to only a single shard (ostensibly in or more local datacenters)
            search_filter = 'ServiceMeta.environment == "%s" and ServiceMeta.shard == "%s"'%(local_environment, local_shard)
            datacenters = local_datacenters
        elif pool_mode == 'local':
            # only search the local datacenter for shards
            datacenters = local_datacenters
        elif pool_mode == 'remote':
            # only search other datacenters
            datacenters = [ x for x in datacenters if x not in local_datacenters]

        consul_service = 'signal'
        consul_shards = {}

        pool_state=False
        # only look up pool state from k/v store if in pool mode
        if pool_mode != 'shard':
            for dc in local_datacenters:
                if not pool_state:
                    pool_state = fetch_pool_state(urls_by_datacenter[dc],dc,local_environment,local_shard)
        if not pool_state:
            pool_state='ready'

        facts = {
            'environment':local_environment,
            'shard':local_shard,
            'xmpp_domain':local_domain,
            'address':default_address,
            'xmpp_host_private_ip_address':default_address,
            'xmpp_host_public_ip_address':default_address,
            'pool_state': pool_state
        }

        for dc in datacenters:
            consul_url = urls_by_datacenter[dc]
            url='%s/v1/catalog/service/%s'%(consul_url,consul_service)
            data=urlencode({'filter':search_filter,'dc':dc})
            response=json_from_url(url+'?'+data, timeout=CONSUL_REQUEST_TIMEOUT)

            if response:
                for service in response:
                    shard_fact=fact_from_service(service, dc)
                    if shard_fact['shard'] == local_shard:
                        facts['address'] = shard_fact['address']
                        facts['xmpp_host_private_ip_address'] = shard_fact['xmpp_host_private_ip_address']
                        facts['xmpp_host_public_ip_address'] = shard_fact['xmpp_host_public_ip_address']
                    consul_shards[shard_fact['shard']]=shard_fact

        facts['shards'] = consul_shards

    else:
        aws_metadata = json_from_url(aws_metadata_url, timeout=AWS_REQUEST_TIMEOUT)
        instance_id = aws_metadata['instanceId']
        local_region = aws_metadata['region']

        ec2 = boto3.resource('ec2', region_name=local_region)
        local_instance = ec2.Instance(instance_id)
        tags = dict([(x['Key'], x['Value']) for x in local_instance.tags or []])
        local_environment = tags.get(ENVIRONMENT_TAG)
        local_domain = tags.get(XMPP_DOMAIN_TAG)
        local_shard = tags.get(SHARD_TAG)
        if not local_shard:
            local_shard='standalone'
        local_release_number = tags.get(RELEASE_NUMBER_TAG)
        if not local_release_number:
            local_release_number=''

        if local_environment:
            filters = [
                    {'Name': 'instance-state-name', 'Values': ['running']},
                    {'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': [SHARD_CORE_ROLE]},
                    {'Name': 'tag:' + SHARD_TAG, 'Values': [local_shard]},
                    {'Name': 'tag:'+ ENVIRONMENT_TAG, 'Values':[local_environment]}
                ]

            instances = ec2.instances.filter(Filters=filters)
            facts = False
            for xmpp_host in instances:
                facts = fact_from_instance(xmpp_host,local_data)

            if not facts:
                facts = {'environment':local_environment,'shard':local_shard,'xmpp_domain':local_domain,'address':default_address,'xmpp_host_private_ip_address':default_address, 'xmpp_host_public_ip_address':default_address}


            if 'enable_cross_region' in local_data and local_data['enable_cross_region']:
                facts['shards'] = {}
                for region in local_data['regions']:
                    filters = [
                            {'Name': 'instance-state-name', 'Values': ['running']},
                            {'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': [SHARD_CORE_ROLE]},
                            {'Name': 'tag:' + RELEASE_NUMBER_TAG, 'Values': [local_release_number]},
                            {'Name': 'tag:'+ ENVIRONMENT_TAG, 'Values':[local_environment]}
                        ]
                    ec2 = boto3.resource('ec2', region_name=region)
                    instances = ec2.instances.filter(Filters=filters)
                    if instances:
                        for instance in instances:
                            shard_fact=fact_from_instance(instance,local_data)
                            facts['shards'][shard_fact['shard']]=shard_fact
            else:
                # disable cross-connecting of shards, only connect to local shard
                facts['shards'] = {local_shard: dict(facts)}

    print(json.dumps(facts))

    #now read the server states from haproxy
    # server_states = read_haproxy_server_states()
    # print(server_states)


if __name__ == '__main__':
    main()
