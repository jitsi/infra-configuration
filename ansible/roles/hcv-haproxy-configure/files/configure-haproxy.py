#!/usr/bin/python
from __future__ import print_function

from urllib.request import urlopen, build_opener, HTTPCookieProcessor
from urllib.parse import urlencode

import json
import os
import boto3
import re
from subprocess import Popen, PIPE, check_output
import time
import sys
import traceback
import logging
import base64

import socket

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

CONSUL_REQUEST_TIMEOUT=5
AWS_REQUEST_TIMEOUT=5
RETRY_SLEEP=1

SHARD_CORE_ROLE = "core"
SHARD_HAPROXY_ROLE = "haproxy"
ENVIRONMENT_TAG = "environment"
XMPP_DOMAIN_TAG = "domain"
PUBLIC_DOMAIN_TAG = "public_domain"
SHARD_TAG = "shard"
SHARD_ROLE_TAG = "shard-role"
SHARD_STATE_TAG = "shard-state"
SHARD_AGE_TAG = "shard-age"

SERVER_STATE_FILE="/tmp/server_state"
HAPROXY_ADMIN_SOCKET="/var/run/haproxy/admin.sock"

# haproxy configuration file to manage
HAPROXY_DEFAULTS_FILE = "/etc/default/haproxy"
EC2_REGION_FILE = "/etc/regions.txt"
BACKEND_NAME = "nodes"

FACT_CACHE_FILE = "/tmp/haproxy-facts.json"

#deprecated: no longer have a shard 0
# TODO: remove everywhere at once
# remove any non-digit items, add 10 to ensure shard s0 doesn't end up as 0 (invalid haproxy backend id)
SHARD_ID_OFFSET = 10

#SHARD_ID_OFFSET = 0

local_data_path = "/etc/environment.json"
aws_metadata_url = 'http://169.254.169.254/latest/dynamic/instance-identity/document'
aws_public_ipv4_url = 'http://169.254.169.254/latest/meta-data/public-ipv4'

urls_by_datacenter = {}
releases = set([])

def peer_from_service(service,datacenter):
    global local_ipv4
    environment = service['ServiceMeta']['environment']
    public_ip = None
    private_ip = None
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
        private_ip = service['Address']

    peer = {'datacenter':datacenter}
    peer['private_ip'] = private_ip
    if public_ip:
        peer['public_ip'] = public_ip
        peer['peer_ip'] = public_ip
    else:
        peer['peer_ip'] = private_ip

    peer['environment'] = environment

    # if  public_ipv4 == peer['public_ip']:
    #     #if we found our local entry, then address ourselves by private IP address
    #     peer['peer_ip'] = peer['private_ip']
    # else:
    #     #otherwise default to addressing each peer by public IP address
    #     peer['peer_ip'] = peer['public_ip']

    peer['peername'] = peer['environment'] + '-haproxy-'+''.join(peer['peer_ip'].split('.')[2:4])

    return peer

def backend_from_service(consul_url,service,datacenter,local_datacenters):
    global releases
    environment = service['ServiceMeta']['environment']
    domain = service['ServiceMeta']['domain']
    release_number = service['ServiceMeta']['release_number']
    releases.add(release_number)
    agent_port = 6060
    backend_port = 443
    if 'signal_sidecar_agent_port' in service['ServiceMeta']:
        agent_port = int(service['ServiceMeta']['signal_sidecar_agent_port'])

    if 'http_backend_port' in service['ServiceMeta']:
        backend_port = int(service['ServiceMeta']['http_backend_port'])

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
        public_ip = private_ip = service['Address']

    if 'shard' in service['ServiceMeta']:
        shard = hostname = service['ServiceMeta']['shard']
        #pull out the last item in the name (if shard is chaos-s1 then shard_id is s1)
        shard_id = shard.split('-')[-1]
        #remove any non-digit items, add SHARD_ID_OFFSET to ensure shard s0 doesn't end up as 0 (invalid haproxy backend id) (deprecated, offset is 0 by default)
        shard_id = SHARD_ID_OFFSET + int(re.sub(r'\D','',shard_id))
    else:
        # standalone instance, so use domain for shard, and privateIP for shard_id
        shard = domain
        hostname = domain
        shard_id = int(''.join(private_ip.split('.')[1:]))

    shard_state = fetch_shard_state(consul_url,datacenter,environment,shard)
    if not shard_state:
        shard_state='drain'

    if not hostname:
        hostname = service['Node']

    backend = {
        'id': shard_id,
        'datacenter': datacenter,
        'environment': environment,
        'domain': domain,
        'shard': shard,
        'shard_state': shard_state,
        'hostname': hostname,
        'private_ip': private_ip,
        'public_ip': public_ip,
        'agent_port': agent_port,
        'backend_port': backend_port,
        'release_number': release_number,
    }

    if backend['datacenter'] in local_datacenters:
        #local to our region, so don't mark it as a backup
        backend['local'] = True
    else:
        #since this backend isn't in any of our local regions, mark it as a backup
        backend['local'] = False

    return backend



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

def fetch_shard_state(consul_url, datacenter, environment, shard):
    shard_key='shard-states/%s/%s'%(environment,shard)
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


def fetch_service_hosts(consul_url, environment, datacenter, include_standalone=False):
    services = ['signal']
    out = []
    if include_standalone:
        services.append('all')
    for s in services:
        url='%s/v1/catalog/service/%s'%(consul_url,s)
        data=urlencode({'filter':'ServiceMeta.environment == "%s"'%environment,'dc':datacenter})
        results = json_from_url(url+'?'+data, timeout=CONSUL_REQUEST_TIMEOUT)
        if results:
            out = out + results

    return out

def fetch_peer_hosts(consul_url, environment, datacenter):
    url='%s/v1/catalog/service/haproxy'%consul_url
    data=urlencode({'filter':'ServiceMeta.environment == "%s"'%environment,'dc':datacenter})
    results = json_from_url(url+'?'+data, timeout=CONSUL_REQUEST_TIMEOUT)
    if results:
        return results
    else:
        return []

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

def fetch_live_release(consul_url, environment):
    key = "releases/{}/live".format(environment)
    url = '{}/v1/kv/{}'.format(consul_url, key)
    results = json_from_url(url, timeout=CONSUL_REQUEST_TIMEOUT)
    if results and results[0]['Key'] and results[0]['Key'] == key and results[0]['Value']:
        return base64.b64decode(results[0]["Value"]).decode('ascii')
    return None


def read_haproxy_server_states():
    global HAPROXY_ADMIN_SOCKET

    p1=Popen(["echo", "show stat"],stdout=PIPE)
    p2=check_output(["socat",HAPROXY_ADMIN_SOCKET,"stdio"],stdin=p1.stdout).splitlines()
    states= p2

    return states


def fetch_instance_data(instanceId, region):
    """Generate instance environment by instanceId
    """
    global local_ipv4
    global public_ipv4
    global local_environment
    global domain
    global hostname
    global local_peer

    ec2 = boto3.resource('ec2', region_name=region)
    instance = ec2.Instance(instanceId)
    tags = dict([(x['Key'], x['Value']) for x in instance.tags or []])
    local_environment = tags.get(ENVIRONMENT_TAG)
    xmpp_domain = tags.get(XMPP_DOMAIN_TAG)
    public_domain = tags.get(PUBLIC_DOMAIN_TAG)
    public_ipv4 = instance.public_ip_address
    local_ipv4 = instance.private_ip_address
    local_peer = peer_from_instance(instance,region)

    if not public_domain: domain = xmpp_domain
    else: domain = public_domain
    peer_id = 'haproxy-'+''.join(public_ipv4.split('.')[2:4])
    hostname = local_environment + "-" + peer_id + "." + domain

    # Add new tag with hostname to the AWS
    tag = instance.create_tags(
        DryRun=False,
        Tags=[
            {
                'Key': 'Name',
                'Value': hostname
            },
        ]
    )


def fetch_aws_data():
    """ Pull environment details from instance metadata
    """
    global instance_id
    global local_region

    aws_metadata = json.loads(urlopen(aws_metadata_url).read())
    instance_id = aws_metadata['instanceId']
    local_region = aws_metadata['region']
    regions = []
    if os.path.isfile(EC2_REGION_FILE):
        with open(EC2_REGION_FILE, "r") as regionfile:
            regions =[ word for line in regionfile for word in line.split() ]

    #remove local region as we're going to put it at the top
    if local_region in regions:
        regions.remove(local_region)

    regions.insert(0,local_region)

    backends_all = []
    peers = []

    #fetch metadata for localinstabce
    fetch_instance_data(instance_id,local_region)

    for region in regions:
        #pull the list of all instances we care about in our region
        instances = fetch_instances(region)

        #get all nodes with the haproxy shard-role tag (haproxy hosts)
        haproxy_instances = [ i for i in instances if [t for t in i.tags if t['Key'] == SHARD_ROLE_TAG][0]['Value'] == SHARD_HAPROXY_ROLE ]

        #get all nodes with the core shard-role tag(xmpp hosts)
        all_core_instances = [ i for i in instances if [t for t in i.tags if t['Key'] == SHARD_ROLE_TAG][0]['Value'] == SHARD_CORE_ROLE ]
        #get all core nodes in the ready state
        core_ready_instances = [ i for i in all_core_instances if [t for t in i.tags if t['Key'] == SHARD_STATE_TAG][0]['Value'] == 'ready' ]

        # for i in all_core_instances:
        #     backends_all.append(backend_from_instance(i,region))

        for i in all_core_instances:
            backends_all.append(backend_from_instance(i,region))

        for i in haproxy_instances:
            peers.append(peer_from_instance(i,region))


    return {'peers':peers,'backends':backends_all}


def peer_from_instance(instance,region):
    global local_ipv4
    tags = dict([(x['Key'], x['Value']) for x in instance.tags or []])
    peer = {'region':region}
    peer['public_ip'] = instance.public_ip_address
    peer['private_ip'] = instance.private_ip_address
    peer['environment'] = tags.get(ENVIRONMENT_TAG)
    peer['peername'] = peer['environment'] + '-haproxy-'+''.join(peer['public_ip'].split('.')[2:4])

    if  public_ipv4 == peer['public_ip']:
        #if we found our local entry, then address ourselves by private IP address
        peer['peer_ip'] = peer['private_ip']
    else:
        #otherwise default to addressing each peer by public IP address
        peer['peer_ip'] = peer['public_ip']
    return peer


def backend_from_instance(instance,region):
    backend = {'region':region}

    if backend['region'] == local_region:
        #local to our region, so don't mark it as a backup
        backend['local'] = True
    else:
        #since this backend isn't in any of our local regions, mark it as a backup
        backend['local'] = False

    backend['shard'] = [t for t in instance.tags if t['Key'] == SHARD_TAG][0]['Value']
    backend['shard_state'] = [t for t in instance.tags if t['Key'] == SHARD_STATE_TAG][0]['Value']
    backend['public_ip'] = instance.public_ip_address
    backend['private_ip'] = instance.private_ip_address
    backend['hostname'] = [t for t in instance.tags if t['Key'] == 'Name'][0]['Value']

    #pull out the last item in the name (if shard is hcv-chaos-s1 then shard_id is s1)
    shard_id = backend['shard'].split('-')[-1]

    #remove any non-digit items, add 10 to ensure shard s0 doesn't end up as 0 (invalid haproxy backend id)
    shard_id = 10 + int(re.sub(r'\D','',shard_id))
    backend['id'] = shard_id

    return backend


def fetch_instances(region):
    try:
        ec2 = boto3.resource('ec2',region_name=region)
        filters = [
            {'Name': 'instance-state-name', 'Values': ['running']},
            {'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': [SHARD_CORE_ROLE,SHARD_HAPROXY_ROLE]},
            {'Name':'tag:'+ ENVIRONMENT_TAG, 'Values':[local_environment]}
        ]

        instances = ec2.instances.filter(Filters=filters)
        return instances
    except Exception as e:
        logging.warning("failed to fetch instances from AWS: %s"%e)
        return []


def build_haproxy_variables(backends, peers, datacenters, local_instance={}, live_release=None):
    """ Build local variables for Ansible
    :return: Json to the standard output
    """
    global releases
    facts = {
        'local_instance': {
            'hostname': hostname,
            'public_ip': public_ipv4,
            'local_region': local_region
        },
        'backends': backends,
        'peers': peers,
        'releases': list(releases),
        'datacenters': datacenters,
        'live_release': live_release,
    }

    with open(FACT_CACHE_FILE, 'w') as outfile:
        json.dump(facts, outfile)


def fetch_consul_data(consul_urls, local_environment, local_datacenters, datacenters, include_standalone=False):
    global hostname
    global local_region
    global local_peer
    global urls_by_datacenter

    hostname = socket.gethostname()
    local_peer = {'peername': hostname.split('.')[0]}
    backends = []
    peers = []
    for dc in datacenters:
        consul_url = urls_by_datacenter[dc]
        results = fetch_service_hosts(consul_url, local_environment, dc, include_standalone)

        for service in results:
            backends.append(backend_from_service(consul_url, service, dc, local_datacenters))

        results = fetch_peer_hosts(consul_url, local_environment, dc)
        for service in results:
            peers.append(peer_from_service(service, dc))

    live_release = fetch_live_release(urls_by_datacenter[local_datacenters[0]], local_environment)

    return {'backends': backends, 'peers': peers, 'live_release': live_release}

def main():
    local_data = False
    global public_ipv4
    global local_ipv4
    global local_region

    #use local environment details saved to the filesystem
    try:
        with open(local_data_path,'r') as f:
            local_data = json.loads(f.read())
    except Exception as e:
        #error happened
        logging.warning("Error loading local data file for haproxy configuration local facts %s"%e)

    if local_data and 'consul_enabled' in local_data and local_data['consul_enabled']:
        if 'consul_server' in local_data and local_data['consul_server']:
            consul_urls= ['https://%s'%local_data['consul_server']]
        else:
            consul_urls = ['http://localhost:8500']

        if 'consul_extra_urls' in local_data:
            consul_urls.extend(local_data['consul_extra_urls'])

        local_environment = local_data['environment']
        public_ipv4 = local_ipv4 = local_data['private_ip']
        if 'public_ip' in local_data and local_data['public_ip']:
            public_ipv4 = local_data['public_ip']

        local_region = local_data['region']

        # by default only consider first datacenter as local
        enable_cross_region = False
        if 'enable_cross_region' in local_data:
            # if enabled, consider first datacenter in each response as local
            enable_cross_region = local_data['enable_cross_region']

        # get other datacenters from consul
        datacenters = []
        local_datacenters = []
        for consul_url in consul_urls:
            segment_dcs = fetch_datacenters(consul_url)
            if segment_dcs:
                datacenters.extend(segment_dcs)
                if enable_cross_region or len(local_datacenters) == 0:
                    # mark the first DC in each list as 'local'
                    local_datacenters.append(segment_dcs[0])

        # order datacenters based on proximity from EC2_REGION_FILE
        ordered_datacenters = []
        if os.path.isfile(EC2_REGION_FILE):
            ordered_aws_regions = []
            with open(EC2_REGION_FILE, "r") as regionfile:
                ordered_aws_regions = [ word for line in regionfile for word in line.split() ]

            for aws_region in ordered_aws_regions:
                # derive OCI region from AWS region and add to list if found in consul datacenters
                if aws_region in local_data['aws_to_oracle_region_map'].keys():
                    oci_region = local_data['aws_to_oracle_region_map'][aws_region] 
                    ordered_datacenters.extend([i for i in datacenters if oci_region in i])

                # de-alias AWS region and add to list if found in consul datacenters
                if aws_region in local_data['aliased_regions'].keys():
                    aws_region = local_data['aliased_regions'][aws_region]
                ordered_datacenters.extend([i for i in datacenters if aws_region in i])

        else:
            ordered_datacenters = datacenters
            logging.warning('{} not found; unable to order datacenters'.format(EC2_REGION_FILE))

        logging.info('original datacenters: {}'.format(datacenters))
        logging.info('ordered datacenters: {}'.format(ordered_datacenters))

        include_standalone = False
        if 'include_standalone' in local_data and local_data['include_standalone']:
            include_standalone = True

        consul_data = fetch_consul_data(consul_urls, local_environment, local_datacenters, ordered_datacenters, include_standalone)

        build_haproxy_variables(backends=consul_data['backends'], peers=consul_data['peers'], datacenters=ordered_datacenters, live_release=consul_data['live_release'])

    else:
        aws_data = fetch_aws_data()
        build_haproxy_variables(backends = aws_data['backends'], peers = aws_data['peers'], datacenters=ordered_datacenters, local_instance = fetch_instances)

    #now read the server states from haproxy
    # server_states = read_haproxy_server_states()
    # print(server_states)


if __name__ == '__main__':
    main()
