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
import logging
import time
import sys
import traceback

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

from pyjavaproperties import Properties

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
RETRY_SLEEP=1

configfile_path = "/etc/jitsi/jigasi/sip-communicator.properties"
local_data_path = "/etc/jitsi/jigasi/environments.json"
aws_metadata_url = 'http://169.254.169.254/latest/dynamic/instance-identity/document'
aws_public_ipv4_url = 'http://169.254.169.254/latest/meta-data/public-ipv4'
control_pid_url = 'http://localhost:8788/configure/call-control-muc/list'

urls_by_datacenter={}

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

def list_live_pids():
    pids = json_from_url(control_pid_url, timeout=5)
    if pids == None:
        eprint('No live control mucs found, not assuming any current configured mucs in jigasi')
        return []
    else:
        return pids

def list_config_pids():
    p = Properties()
    p.load(open(configfile_path))
    config_pids = set()
    for prop in p.items():
        if prop[0].startswith('net.java.sip.communicator.impl.protocol.jabber'):
            pid_pieces=prop[0].split('.')
            if len(pid_pieces) > 7:
                pid = prop[0].split('.')[7]
                if pid.startswith('acc-'):
                    config_pids.add(pid)

    return config_pids


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
        'jid': '%s@%s.%s'%(local_data['jid_username'],local_data['auth_prefix'],extract_tag(instance.tags,XMPP_DOMAIN_TAG)),
        'xmpp_muc': '%s.%s'%(local_data['internal_muc_prefix'],extract_tag(instance.tags,XMPP_DOMAIN_TAG)),
    }

    if not fact['id']:
        fact['id'] = extract_tag(instance.tags,NAME_TAG);

    if 'url' in environment_detail and environment_detail['url']:
        fact['url'] = environment_detail['url']

    return fact

def fact_from_service(service, local_data):
    host_port = 5222
    environment = service['ServiceMeta']['environment']
    domain = service['ServiceMeta']['domain']
    if 'prosody_client_port' in service['ServiceMeta']:
        host_port = int(service['ServiceMeta']['prosody_client_port'])
    if service['ServiceID'] == 'all':
        shard = domain.replace('.','-')
    else:
        shard = service['ServiceMeta']['shard']
    if 'ServiceTaggedAddresses' in service:
        private_ip = service['ServiceTaggedAddresses']['lan']['Address']
        public_ip = service['ServiceTaggedAddresses']['wan']['Address']
    else:
        private_ip = public_ip = service['Address']

    environment_detail = {}
    for e in local_data['environments']:
        if e['name'] == environment:
            environment_detail = e
            break

    fact = {
        'environment': environment,
        'shard': shard,
        'xmpp_domain': domain,
        'xmpp_host_private_ip_address': private_ip,
        'xmpp_host_public_ip_address': public_ip,
        'host_port': host_port,
        'id': shard,
        'address': private_ip,
        'jid': '%s@%s.%s'%(local_data['jid_username'],local_data['auth_prefix'],domain),
        'xmpp_muc': '%s.%s'%(local_data['internal_muc_prefix'],domain),
    }

    if not fact['id']:
        fact['id'] = service['Node']

    if 'url' in environment_detail and environment_detail['url']:
        fact['url'] = environment_detail['url']

    return fact

def fetch_service_hosts(consul_url, environment, datacenter):
    consul_services = ['signal','all']
    out = []

    for service in consul_services:
        url='%s/v1/catalog/service/%s'%(consul_url,service)
        data=urlencode({'filter':'ServiceMeta.environment == "%s"'%environment,'dc':datacenter})
        results = json_from_url(url+'?'+data, timeout=CONSUL_REQUEST_TIMEOUT)
        if results:
            out.extend(results)
    return out

def fetch_datacenters(consul_url):
    global urls_by_datacenter
    out_results = []
    url='%s/v1/catalog/datacenters'%consul_url
    results = json_from_url(url, timeout=CONSUL_REQUEST_TIMEOUT)
    if results:
        for r in results:
            out_results.append(r)
            urls_by_datacenter[r] = consul_url

    return out_results

def main():
    global urls_by_datacenter

    hosts = []
    remove_hosts = []
    #ignore local shard for now
    local_shard = False
    local_data = False

    #use local environment details saved to the filesystem
    try:
        with open(local_data_path,'r') as f:
            local_data = json.loads(f.read())
    except Exception as e:
        #error happened
        logging.warning("Error loading local data file for jigasi configuration local facts %s"%e)


    if local_data and 'consul_enabled' in local_data and local_data['consul_enabled']:
        if 'consul_server' in local_data and local_data['consul_server']:
            consul_urls= ['https://%s'%local_data['consul_server']]
        else:
            consul_urls = ['http://localhost:8500']

        if 'consul_extra_urls' in local_data:
            consul_urls.extend(local_data['consul_extra_urls'])

        local_environment = local_data['local_environment']
        if 'datacenters' in local_data:
            local_datacenters = local_data['datacenters']
        else:
            local_datacenters = []

        enable_cross_region = False
        if 'enable_cross_region' in local_data:
            # if enabled, consider first datacenter in each response as local
            enable_cross_region = local_data['enable_cross_region']

        all_datacenters = []
        for consul_url in consul_urls:
            segment_dcs = fetch_datacenters(consul_url)
            if segment_dcs:
                all_datacenters.extend(segment_dcs)
                if enable_cross_region or len(local_datacenters) == 0:
                    # mark the first DC in first list as 'local'
                    local_datacenters.append(segment_dcs[0])

        environments = [local_environment]

        if enable_cross_region:
            datacenters = all_datacenters
        else:
            datacenters = local_datacenters

        for dc in datacenters:
            if dc in urls_by_datacenter:
                consul_url = urls_by_datacenter[dc]
                for environment in environments:
                    results = fetch_service_hosts(consul_url, environment, dc)

                    for service in results:
                        hosts.append(fact_from_service(service,local_data))
    else:
        aws_metadata = json_from_url(aws_metadata_url, timeout=AWS_REQUEST_TIMEOUT)
        instance_id = aws_metadata['instanceId']
        local_region = aws_metadata['region']

        ec2 = boto3.resource('ec2', region_name=local_region)
        local_instance = ec2.Instance(instance_id)
        tags = dict([(x['Key'], x['Value']) for x in local_instance.tags or []])
        local_environment = tags.get(ENVIRONMENT_TAG)
        local_shard = tags.get(SHARD_TAG)


        if not local_data:
            local_data = {"jid_username":"jigasi", "auth_prefix":"auth","internal_muc_prefix":"internal.auth", "brewery_muc_room":"JigasiBrewery", "regions":[local_region],"environments":[]}

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
            if local_environment == 'all':
                if local_data and len(local_data['environments']) > 0:
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

                for region in local_data['regions']:
                    ec2 = boto3.resource('ec2', region_name=region)
                    instances = ec2.instances.filter(Filters=filters)
                    if instances:
                        for instance in instances:
                            hosts.append(fact_from_instance(instance,local_data))


    # now look for existing hosts from jigasi server
    # TODO: actually query jigasi, for now just grep in the config file
    live_pids = list_live_pids()
    config_pids = set(live_pids)

    host_pids = set([ 'acc-'+x['id'] for x in hosts])
    remove_hosts = list(config_pids - host_pids)
    print(json.dumps({'hosts': hosts, 'remove_hosts': remove_hosts}))

    #now read the server states from haproxy
    # server_states = read_haproxy_server_states()
    # print(server_states)


if __name__ == '__main__':
    main()
