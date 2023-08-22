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

SHARD_CORE_ROLE = "core"
SHARD_STANDALONE_ROLE = "all"
SHARD_HAPROXY_ROLE = "haproxy"
ENVIRONMENT_TAG = "environment"
XMPP_DOMAIN_TAG = "domain"
PUBLIC_DOMAIN_TAG = "public_domain"
SHARD_TAG = "shard"
NAME_TAG = "Name"
SHARD_ROLE_TAG = "shard-role"
SHARD_STATE_TAG = "shard-state"
SHARD_AGE_TAG = "shard-age"

CONSUL_REQUEST_TIMEOUT=5
AWS_REQUEST_TIMEOUT=5
RETRY_SLEEP=10

local_data_path = "/etc/jitsi/jibri/environments.json"
aws_metadata_url = 'http://169.254.169.254/latest/dynamic/instance-identity/document'
aws_public_ipv4_url = 'http://169.254.169.254/latest/meta-data/public-ipv4'

urls_by_datacenter = {}

def fetch_datacenters(consul_urls, enable_cross_region=False):
    global urls_by_datacenter
    out_results = []
    for consul_url in consul_urls:
        url='%s/v1/catalog/datacenters'%consul_url
        results = json_from_url(url, timeout=CONSUL_REQUEST_TIMEOUT)
        if results:
            if enable_cross_region:
                # search in all datacenters
                for r in results:
                    out_results.append(r)
                    urls_by_datacenter[r] = consul_url
            else:
                # only take the first (local) datacenter from the list
                out_results.append(results[0])
                urls_by_datacenter[results[0]] = consul_url


    return out_results

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def json_from_url(url, timeout, retries=3):
    global RETRY_SLEEP
    # Reads JSON from a URL and optionally writes it to a file
    for i in range(0,retries):
        try:
            j = json.loads(urlopen(url,None,timeout=timeout).read())
            return j
        except:
            einfo = sys.exc_info()
            eprint("Unexpected error load from url {}:".format(url), einfo[0])
            traceback.print_tb(einfo[2], file=sys.stderr)
            time.sleep(RETRY_SLEEP)
            # back off more each time
            RETRY_SLEEP=RETRY_SLEEP*2
            continue

    eprint("Failed retrying {} times for url {}:".format(retries, url), sys.exc_info()[0])
    return None


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


def fact_from_instance(instance, local_data=None):
    environment = extract_tag(instance.tags,ENVIRONMENT_TAG)
    shard = extract_tag(instance.tags,SHARD_TAG)
    environment_detail = {}
    for e in local_data['environments']:
        if e['name'] == environment:
            environment_detail = e
            break

    fact = {
        'environment': environment,
        'shard': shard,
        'xmpp_domain': extract_tag(instance.tags,XMPP_DOMAIN_TAG),
        'xmpp_host_private_ip_address': instance.private_ip_address,
        'xmpp_host_public_ip_address': instance.public_ip_address,
        'id': extract_tag(instance.tags,SHARD_TAG),
        'address': instance.public_ip_address,
        'usage_timeout': 0,
        'jid': '%s@%s%s'%(local_data['jid_username'],local_data['auth_prefix'],extract_tag(instance.tags,XMPP_DOMAIN_TAG)),
        'xmpp_muc': '%s%s'%(local_data['internal_muc_prefix'],extract_tag(instance.tags,XMPP_DOMAIN_TAG)),
    }

    if not fact['id']:
        fact['id'] = extract_tag(instance.tags,NAME_TAG)

    if 'url' in environment_detail and environment_detail['url']:
        fact['url'] = environment_detail['url']

    if 'usage_timeout' in environment_detail:
        fact['usage_timeout'] = environment_detail['usage_timeout']

    return fact

def fact_from_service(service, local_data, dc):
    host_port = 5222
    environment = service['ServiceMeta']['environment']
    domain = service['ServiceMeta']['domain']
    if 'prosody_client_port' in service['ServiceMeta']:
        host_port = int(service['ServiceMeta']['prosody_client_port'])
    if 'shard' in service['ServiceMeta']:
        shard = service['ServiceMeta']['shard']
    else:
        shard = ''
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

    environment_detail = {}
    for e in local_data['environments']:
        if e['name'] == environment:
            environment_detail = e
            break

    prefer_private = False
    if dc.startswith(environment):
        prefer_private = True;

    fact = {
        'environment': environment,
        'shard': shard,
        'xmpp_domain': domain,
        'host_port': host_port,
        'xmpp_host_private_ip_address': private_ip,
        'xmpp_host_public_ip_address': public_ip,
        'id': shard,
        'address': private_ip,
        'usage_timeout': 0,
        'jid': '%s@%s%s'%(local_data['jid_username'],local_data['auth_prefix'],domain),
        'xmpp_muc': '%s%s'%(local_data['internal_muc_prefix'],domain),
        'prefer_private': prefer_private
    }

    if not fact['id']:
        fact['id'] = service['Node']

    if 'url' in environment_detail and environment_detail['url']:
        fact['url'] = environment_detail['url']

    if 'usage_timeout' in environment_detail:
        fact['usage_timeout'] = environment_detail['usage_timeout']

    return fact


def main():
    global urls_by_datacenter
    hosts = []

    #use local environment details saved to the filesystem
    local_data = False
    try:
        with open(local_data_path,'r') as f:
            local_data = json.loads(f.read())
    except Exception as e:
        #error happened
        logging.warning("Error loading local data file for jibri configuration local facts %s"%e)
        exit(1)


    consul_urls = []
    if 'consul_urls' in local_data and local_data['consul_urls']:
        consul_urls = local_data['consul_urls']

    if 'consul_server' in local_data and local_data['consul_server']:
        consul_urls= ['https://%s'%local_data['consul_server']]

    if 'consul_extra_urls' in local_data:
        consul_urls.extend(local_data['consul_extra_urls'])

    if 'enable_cross_region' in local_data:
        enable_cross_region=local_data['enable_cross_region']
    else:
        enable_cross_region=False

    if len(consul_urls) > 0:
        local_environment = local_data['local_environment']
        local_domain = local_data['local_domain']
#        datacenters = local_data['datacenters']
        datacenters = fetch_datacenters(consul_urls, enable_cross_region)

        consul_services = ['signal','all']

        if local_data and len(local_data['environments']) > 1:
            environment_names = [x['name'] for x in local_data['environments']]
        else:
            environment_names = [local_environment]

        for dc in datacenters:
            consul_url = urls_by_datacenter[dc]
            for environment in environment_names:
                for consul_service in consul_services:
                    url='%s/v1/catalog/service/%s'%(consul_url,consul_service)
                    data=urlencode({'filter':'ServiceMeta.environment == "%s"'%environment,'dc':dc})
                    response = json_from_url(url+'?'+data, timeout=CONSUL_REQUEST_TIMEOUT)
                    if response:
                        for service in response:
                            if not local_domain or local_domain == service['ServiceMeta']['domain']:
                                hosts.append(fact_from_service(service,local_data, dc))

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
        #ignore local shard for now
        local_shard = False
        if not local_data:
            local_data = {"jid_username":"jibri", "auth_prefix":"auth","internal_muc_prefix":"internal.auth", "brewery_muc_room":"JibriBrewery", "regions":[local_region],"environments":{local_environment:{}}}

        local_data['regions'] = [_f for _f in local_data['regions'] if _f]
        if local_environment and local_shard:
            #running in single shard mode, so only attach to one instance
            filters = [
                    {'Name': 'instance-state-name', 'Values': ['running']},
                    {'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': [SHARD_CORE_ROLE,SHARD_STANDALONE_ROLE]},
                    {'Name': 'tag:' + SHARD_TAG, 'Values': [local_shard]},
                    {'Name': 'tag:'+ ENVIRONMENT_TAG, 'Values':[local_environment]}
                ]

            instances = ec2.instances.filter(Filters=filters)
            if instances:
                for instance in instances:
                    hosts.append(fact_from_instance(instance,local_data))
        elif local_environment:
            if local_data and len(local_data['environments']) > 1:
                environment_names = [x['name'] for x in local_data['environments']]
                #build list of instances for each environment
                filters = [
                        {'Name': 'instance-state-name', 'Values': ['running']},
                        {'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': [SHARD_CORE_ROLE,SHARD_STANDALONE_ROLE]},
                        {'Name': 'tag:'+ ENVIRONMENT_TAG, 'Values':environment_names}
                    ]

                for region in local_data['regions']:
                    ec2 = boto3.resource('ec2', region_name=region)
                    instances = ec2.instances.filter(Filters=filters)
                    if instances:
                        for instance in instances:
                            hosts.append(fact_from_instance(instance,local_data))

            else:
                filters = [
                        {'Name': 'instance-state-name', 'Values': ['running']},
                        {'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': [SHARD_CORE_ROLE,SHARD_STANDALONE_ROLE]},
                        {'Name': 'tag:'+ ENVIRONMENT_TAG, 'Values':[local_environment]}
                    ]
                if local_domain:
                    filters.append({'Name': 'tag:'+ XMPP_DOMAIN_TAG, 'Values':[local_domain]})

                for region in local_data['regions']:
                    ec2 = boto3.resource('ec2', region_name=region)
                    instances = ec2.instances.filter(Filters=filters)
                    if instances:
                        for instance in instances:
                            hosts.append(fact_from_instance(instance,local_data))


    hosts_by_environment_domain = {}
    for h in hosts:
        hkey = h['environment']+'|'+h['xmpp_domain']+'|'+'%s'%h['prefer_private']
        if not hkey in hosts_by_environment_domain:
            hosts_by_environment_domain[hkey] = json.loads(json.dumps(h))
            hosts_by_environment_domain[hkey]['hosts'] = []
            hosts_by_environment_domain[hkey]['host_addresses'] = []

        hosts_by_environment_domain[hkey]['hosts'].append(h)
        hosts_by_environment_domain[hkey]['host_addresses'].append(h['xmpp_host_private_ip_address'])

    print(json.dumps({'hosts_by_environment_domain': hosts_by_environment_domain}))

    #now read the server states from haproxy
    # server_states = read_haproxy_server_states()
    # print(server_states)


if __name__ == '__main__':
    main()
