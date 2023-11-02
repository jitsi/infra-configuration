#!/usr/bin/env python3

# pip install boto3 awscli

import argparse
import pprint

from hcvlib import *


parser = argparse.ArgumentParser(description='Produce a list of AMIs for use in jitsi infrastructure')
parser.add_argument('--batch', action='store_true', default=False,
                   help='Outputs only the IP address matching environment,shard and type.  Meant for use in other tools')
parser.add_argument('--inventory', action='store_true', default=False,
                   help='Outputs ansible inventory format')
parser.add_argument('--role', action='store',
                   help='Role of instance (JVB,Signal,HAProxy,Jibri)', default=False)
parser.add_argument('--environment', action='store',
                   help='Environment of node', default=False)
parser.add_argument('--shard', action='store',
                   help='Shard of node', default=False)
parser.add_argument('--release', action='store',
                   help='Release number of node', default=False)
parser.add_argument('--grid_role', action='store',
                   help='Grid role for selenium grid nodes', default=False)
parser.add_argument('--pool_type', action='store',
                   help='Nomad pool type for nomad pool nodes', default=False)
parser.add_argument('--grid', action='store',
                   help='Grid name for selenium grid nodes', default=False)
parser.add_argument('--public', action='store_true',
                   help='Print public address in batch mode', default=False)
parser.add_argument('--id', action='store_true',
                   help='Print instance ID in batch mode', default=False)
parser.add_argument('--region', action='store',
                   help='EC2 Region', default=AWS_DEFAULT_REGION)
parser.add_argument('--oracle', action='store_true',
                   help='Include oracle instances', default=True)
parser.add_argument('--oracle_only', action='store_true',
                   help='Include ONLY oracle instances', default=False)

parser.add_argument('--fix_node_ips', action='store_true',
                   help='Perform fix IP tag operation', default=False)

args = parser.parse_args()


if args.region.lower() == 'all':
    if args.oracle_only:
        regions = oracle_regions()
    else:
        regions = AWS_REGIONS
else:
    regions = [args.region]

roles = []
nodes = []
if (not args.role or args.role.lower()=='haproxy'):
    roles.append(SHARD_HAPROXY_ROLE)
elif (not args.role or args.role.lower()=='signal'):
    roles.append(SHARD_CORE_ROLE)
elif (not args.role or args.role.lower()=='jvb'):
    roles.append(SHARD_JVB_ROLE)
else:
  roles.append(args.role.lower())

oracle_flag = args.oracle
oracle_only_flag = args.oracle_only
if args.region in oracle_regions():
    oracle_flag=True
    oracle_only_flag=True

if not oracle_only_flag:
    nodes = get_instances_by_role(role_name=roles,environment_name=args.environment,shard_name=args.shard,regions=regions,release_number=args.release,grid=args.grid,grid_role=args.grid_role,pool_type=args.pool_type)
if oracle_flag:
    if not oracle_only_flag:
        regions = convert_aws_regions_to_oracle(regions)
    nodes = nodes + get_oracle_instances_by_role(role_name=roles,environment_name=args.environment,shard_name=args.shard,regions=regions,release_number=args.release,grid=args.grid,grid_role=args.grid_role,pool_type=args.pool_type)

if args.fix_node_ips:
    fix_oci_ip_tags(args.environment, regions)
    exit(0)

if args.inventory:
        # inventory style output for ansible
        if not args.batch:
            print('[nodes]')
        if nodes:
            for i in nodes:
                ip = i.public_ip_address if args.public else i.private_ip_address
                if ip:
                    print('%s inventory_hcv_environment=%s instance_id=%s %s_instance_id=%s inventory_region=%s inventory_cloud_name=%s inventory_cloud_provider=%s public_ip=%s private_ip=%s %s_region=%s'%(
                        ip,
                        args.environment,
                        i.id,
                        i.provider,
                        i.id,
                        i.region,
                        i.cloud_name,
                        i.provider,
                        i.public_ip_address,
                        i.private_ip_address,
                        i.provider,
                        i.region
                    ))
else:
    if not args.batch:
        # table view output 
        print("nodes:")

        print_Instances(nodes)
        print('')
    else:
        # batch output of IPs only, no inventory details
        for i in nodes:
            if args.id:
                print((i.id))
            else:
                if args.public:
                    if i.public_ip_address:
                        print((i.public_ip_address))
                else:
                    if i.private_ip_address:
                        print((i.private_ip_address))
