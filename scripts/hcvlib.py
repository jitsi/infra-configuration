

import boto3
import pprint
import datetime, sys, os
from time import sleep
import inspect
import base64

import requests
from botocore.exceptions import ClientError

from bs4 import BeautifulSoup
import urllib.request, urllib.error, urllib.parse
import re
import yaml
import pdb

import oci

from retry import retry

# table column width
width = 25

ENVIRONMENT_TAG="environment"
SHARD_TAG="shard"
SHARD_ROLE_TAG="shard-role"
SHARD_STATE_TAG="shard-state"
STACK_ROLE_TAG="stack-role"
SHARD_TESTED_TAG="shard-tested"
GRID_TAG="grid"
GRID_ROLE_TAG="grid-role"
DOMAIN_TAG="domain"
RELEASE_NUMBER_TAG="release_number"
CLOUD_PROVIDER_TAG="cloud_provider"
AUTO_SCALE_TAG_NAME="aws:autoscaling:groupName"
REGIONS_FILE_PATH=os.path.dirname(os.path.realpath(__file__))+"/../config/vars.yml"

SHARD_CORE_ROLE="core"
SHARD_JVB_ROLE="JVB"
SHARD_ALL_ROLE="all"
SHARD_HAMMER_ROLE="hammer"
SHARD_TORTURE_ROLE="torture"
SHARD_HAPROXY_ROLE="haproxy"
SHARD_JIBRI_ROLE="jibri"

hcv_debug = False

ORACLE_TENANT= "eghtjitsi"

def oracle_region_map(ansible_var_name=None):
    global ORACLE_REGION_MAP
    ansible_var_name='oracle_to_aws_region_map'
    with open(REGIONS_FILE_PATH, 'r') as f:
        doc = yaml.load(f,Loader=yaml.BaseLoader)

    ORACLE_REGION_MAP=doc[ansible_var_name]

    return ORACLE_REGION_MAP

global ORACLE_REGION_MAP
ORACLE_REGION_MAP = oracle_region_map()

def oracle_regions():
    global ORACLE_REGION_MAP
    global ORACLE_REGIONS

    ORACLE_REGIONS = list(ORACLE_REGION_MAP.keys())
    return ORACLE_REGIONS

def oracle_regions_by_aws():
    map = {}
    for r in ORACLE_REGION_MAP.keys():
        map[ORACLE_REGION_MAP[r]] = r

    return map

def load_region_aliases():
    ansible_var_name='region_aliases'
    with open(REGIONS_FILE_PATH, 'r') as f:
        doc = yaml.load(f,Loader=yaml.BaseLoader)

    region_aliases = doc[ansible_var_name]
    return region_aliases

def region_from_alias(region_alias):
    region_aliases = load_region_aliases()
    if region_alias in region_aliases:
        region_name = region_aliases[region_alias]
    else:
        region_name = region_alias

    return region_name

def alias_from_region(region):
    region_aliases = load_region_aliases()
    # default to region name for alias
    region_alias = region
    for alias,r in region_aliases:
        if r == region:
            region_alias = alias
            break
        
    return region_alias

def aws_regions(ansible_var_name=None):
    """
    Get regions from ansible group vars file.
    ansible_var_name: it is variable name from ansible env file with regions or clouds
    :return: List of regions or clouds
    """
    global AWS_REGIONS

    if ansible_var_name is None:
        ansible_var_name="all_regions"

    with open(REGIONS_FILE_PATH, 'r') as f:
        doc = yaml.load(f,Loader=yaml.BaseLoader)

    if isinstance(doc[ansible_var_name], list):
        AWS_REGIONS = doc[ansible_var_name]
    else:
        # assume newline-separated string
        AWS_REGIONS = list(doc[ansible_var_name].splitlines())

    return AWS_REGIONS

AWS_REGIONS=aws_regions()

def aws_default_region(ansible_var_name=None):
    """
    Get default region from ansible group vars file.
    ansible_var_name: it is variable name from ansible env file with default region
    :return: String with default region
    """
    global AWS_DEFAULT_REGION

    if ansible_var_name is None:
        ansible_var_name="default_region"

    with open(REGIONS_FILE_PATH, 'r') as f:
        doc = yaml.load(f,Loader=yaml.BaseLoader)
    AWS_DEFAULT_REGION = (doc[ansible_var_name].splitlines())[0]

    return AWS_DEFAULT_REGION

AWS_DEFAULT_REGION= aws_default_region()

def aws_regions_to_bash(default_var_name):
    """
    Create list of regions from ansible and return it into bash scripts.
    default_var_name: String, it is variable name from ansible env file with regions or clouds
    :return: string with regions
    """
    default_vars = default_var_name
    regions = ""

    for r in aws_regions(default_vars):
        regions += r + " "
    print((regions[0:-1]))

def deb_package_version_soup():
    request = urllib.request.Request(JITSI_REPO_URL)
    base64string = base64.encodestring('%s:%s' % (JITSI_REPO_USER, JITSI_REPO_PASSWORD)).replace('\n', '')
    request.add_header("Authorization", "Basic %s" % base64string)
    html_page = urllib.request.urlopen(request)
    return BeautifulSoup(html_page)

def deb_package_versions(prefix='ji',arch=None, soup=None):
    if not soup:
        soup = deb_package_version_soup() 

    #build a list of the unique set of a list of hrefs built from finding all the <a> tags in the document and ignoring any without a .deb or having certain other notable characteristics
    packages = list(set([ link.get('href').split('_')[1] for link in soup.findAll('a') if (not prefix or link.get('href').startswith(prefix)) and (not arch or link.get('href').endswith(str(arch)+'.deb')) and 'token' not in link.get('href') and 'latest' not in link.get('href') ]))

    #versions look like: '1.0-237-1' or '1.0.1002-1' or '725-1'
    #so first we split on '.' and take the final field (0-237-1, 1002-1, 725-1 respectively)
    #then we split on '-'' and take the second-to-last field (237,1002,725 respectively)
    packages.sort(reverse=True, key=lambda x: raw_version_from_deb_package_version(x))
    return packages

def raw_version_from_deb_package_version(x):
    return int(x.split('.')[-1].split('-')[-2])

def jvb_deb_package_versions(soup=None):
    return deb_package_versions('jitsi-videobridge',soup=soup)

def jicofo_deb_package_versions(soup=None):
    return deb_package_versions('jicofo',soup=soup)

def jitsi_meet_deb_package_versions(soup=None):
    return deb_package_versions('jitsi-meet',soup=soup)

def format_ip_address_list(instances, extra_instances):
    return ' '.join(map(extract_ip_address, instances))+' '.join(map(extract_ip_address, extra_instances))

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

def cloud_from_network_stack(stack, region):
    cloud = {'region': region}
    cloud['name'] = [t for t in stack.tags if t['Key'] == 'Name'][0]['Value']
    #drop the '-network' off the end of the name
    cloud['name'] = '-'.join(cloud['name'].split('-')[:-1])
    return cloud

def get_cloud_list():
    global AWS_REGIONS
    out_clouds = []
    for s in get_cloudformation_by_stack_role(role='network'):
        out_clouds.append(cloud_from_network_stack(s,region=s.region))

    return out_clouds

def warning(warn_str):
    print(warn_str, file=sys.stderr)

def get_account_id():
    try:
        # We're running in an ec2 instance, get the account id from the
        # instance profile ARN
        return requests.get(
            'http://169.254.169.254/latest/meta-data/iam/info/',
            timeout=1).json()['InstanceProfileArn'].split(':')[4]
    except:
        pass

    try:
        # We're not on an ec2 instance but have api keys, get the account
        # id from the user ARN
        return boto3.resource('iam').CurrentUser().arn.split(':')[4]
    except:
        pass

    return False

def get_stable_versions(image_type):

    if image_type == 'JVB':
        return ['1075', '1063', '1056', '1055', '1043', '1039', '1036', '1033', '1030', '1024', '1021', '1017', '1013', '1011', '1010', '997', '995', '991', '990', '985', '976', '968', '967', '961', '958', '953', '937', '929', '925', '914', '909', '882', '879', '869', '856', '843', '840', '836','820','808','801','796','770','765','757','751','746','738','731']
    elif image_type == 'Signal':
        return ['423-2929', '417-2866', '406-2781', '405-2740', '398-2706','398-2676', '398-2667', '397-2649', '396-2630', '394-2608', '394-2579', '394-2569', '394-2561', '394-2555', '392-2502', '390-2489', '390-2484', '388-2459', '388-2441', '386-2430', '371-2367', '371-2301', '369-2273', '366-2250', '365-2212', '363-2182', '361-2116', '359-2081', '357-2031', '357-2015', '357-2009', '357-1991', '357-1976', '357-1967', '348-1924', '344-1891', '344-1862', '341-1738','337-1738', '334-1700', '333-1688', '324-1631', '322-1614', '320-1592', '319-1575', '316-1559', '308-1503', '304-1465', '304-1452','301-1417','300-1409','298-1338','296-1320','295-1294','292-1217','287-1209','276-1157','275-1115']
    elif image_type == 'Jigasi':
        return ['175', '166', '142']
    elif image_type == 'HAProxy':
        return []
    else:
        return []

def get_stable_versions_by_package():
    stable_versions_by_package = {}
    signal_versions = get_stable_versions('Signal')
    jicofo_versions=set()
    jitsi_meet_versions=set()
    for signal_version in signal_versions:
        version_arr = signal_version.split('-')
        jicofo_versions.add(version_arr[0])
        jitsi_meet_versions.add(version_arr[1])

    stable_versions_by_package['jitsi-videobridge'] = get_stable_versions('JVB')
    stable_versions_by_package['jicofo'] = list(jicofo_versions)
    stable_versions_by_package['jitsi-meet'] = list(jitsi_meet_versions)
    stable_versions_by_package['jitsi-meet-prosody'] = list(jitsi_meet_versions)
    stable_versions_by_package['jitsi-meet-tokens'] = list(jitsi_meet_versions)
    stable_versions_by_package['jitsi-meet-web'] = list(jitsi_meet_versions)
    stable_versions_by_package['jitsi-meet-web-config'] = list(jitsi_meet_versions)

    return stable_versions_by_package

def clean_repo_directory(directory, count_to_keep=30, dryRun=True):
    #package types of manage
    packages_to_clean = ['jitsi-videobridge','jitsi-meet','jitsi-meet-tokens','jitsi-meet-web','jitsi-meet-web-config','jicofo','jitsi-meet-prosody','hipchat-me','banana-video']
    #first list all files in directory
    files = os.listdir(directory)
    #split them up by package type
    files_by_package = {}
    for f in files:
        #first let's only use things that end in .deb or .changes
        if '.deb' in f or '.changes' in f:
            (package,version,arch) = f.split('_')
            if package in packages_to_clean:
                if not package in files_by_package:
                    files_by_package[package] = []

                if package == 'hipchat-me':
                    raw_version = '.'.join(version.split('-')[0].split('.')[2:4])
                elif package == 'banana-video':
                    raw_version = '.'.join(version.split('-')[0].split('.')[2:4])
                else:
                    raw_version = raw_version_from_deb_package_version(version)

                files_by_package[package].append({'package':package,'raw_version':raw_version, 'version':version,'filename':os.path.join(directory,f)})

    files_to_remove = []
    #pull list of stable versions per package
    for package in files_by_package:
        #sort list by version #
#        files_by_package[package].sort(key=lambda f: f['version'])
        #filter out any versions which we wish to keep
        files_by_package[package] = filter_stable_packages(package, files_by_package[package])
        versions = list(set([f['raw_version'] for f in files_by_package[package]]))

        if len(versions) > count_to_keep:
            versions.sort(reverse=True, key=lambda v: version_sort_value(v))
            versions_to_remove = versions[count_to_keep:]
        else:
            #nothing to do for this package type, less than the max count of items
            versions_to_remove = []

        files_by_package[package].sort(reverse=True, key=lambda v: version_sort_value(v['raw_version']))
        files_to_remove += [f['filename'] for f in files_by_package[package] if f['raw_version'] in versions_to_remove]

    for f in files_to_remove:
        if dryRun:
            print(('%s would be deleted'%f))
        else:
            print(('%s deleted'%f))
            os.remove(f)

def clean_s3_cdn(bucket, package, count_to_keep_s3=20, dryRun=True):
    """ Delete old version from AWS S3 storage.

    Kwargs:
        bucket  -- the S3 bucket name
        package -- the package name which version we will delete
        count_to_keep_s3 -- how many unstable versions of package we will keep (default 20)
        dryRun -- only print the name of the files to delete, do not actually delete them (default True)

    """
    count_to_keep_s3 = int(count_to_keep_s3)

    client = boto3.client('s3')
    response = client.list_objects(Bucket=bucket, Delimiter='/')

    #list of object
    object_dict = []
    #List of object to remove from S3
    objects_to_remove = []
    #List of full path to objects to remove
    objects_to_remove_path = []

    #Pull list of versions and objects name from S3
    for i in response['CommonPrefixes']:
        object_name = i['Prefix']

        if package == 'jitsi-meet':
            if "hipchatme" not in object_name:
                if "bananavideo" not in  object_name:
                    object_raw_version = str(re.sub('/', '', object_name))
                    if object_raw_version.isdigit():
                        object_dict.append({ 'name' : object_name, 'raw_version' : object_raw_version })
        elif package == 'hipchat-me':
            if "hipchatme" in object_name:
                # object_raw_version = re.split('[_\.]',object_name,re.UNICODE)[1]
                object_raw_array = re.split('[_]', object_name, re.UNICODE)
                if len(object_raw_array) > 1:
                    object_raw_version = object_raw_array[1]
                    object_version_array = re.split('[-]', object_raw_version, re.UNICODE)
                    object_raw_version = object_version_array[0]
                    object_raw_version = str(re.sub('/', '', object_raw_version))
                    object_dict.append({ 'name' : object_name, 'raw_version' : object_raw_version })
                else:
                    print(("Skipping unmatched object %s"%object_name))
        elif package == 'banana-video':
            if "bananavideo" in object_name:
                # object_raw_version = re.split('[_\.]',object_name,re.UNICODE)[1]
                object_raw_array = re.split('[_]', object_name, re.UNICODE)
                if len(object_raw_array) > 1:
                    object_raw_version = object_raw_array[1]
                    object_version_array = re.split('[-]', object_raw_version, re.UNICODE)
                    object_raw_version = object_version_array[0]
                    object_raw_version = str(re.sub('/', '', object_raw_version))
                    object_dict.append({ 'name' : object_name, 'raw_version' : object_raw_version })
                else:
                    print(("Skipping unmatched object %s"%object_name))

    #Pull object that not in stable package list
    object_dict = filter_stable_packages(package, object_dict)
    # Pull raw versions from S3
    versions = list(set([o['raw_version'] for o in object_dict]))

    if len(versions) > count_to_keep_s3:
        versions.sort(reverse=True, key=lambda v: version_sort_value(v))
        versions_to_remove = versions[count_to_keep_s3:]
    else:
        #nothing to do for this package type, less than the max count of items
        versions_to_remove = []

    object_dict.sort(reverse=True, key=lambda v: version_sort_value(v['raw_version']))
    objects_to_remove += [str(o['name']) for o in object_dict if o['raw_version'] in versions_to_remove]

    if dryRun:
        for o in objects_to_remove:
            print(('%s would be deleted'%o))
    else:
        for o in objects_to_remove:
            print(('%s deleted'%o))
            s3_del_limit = 900
            response = client.list_objects(Bucket=bucket, Prefix=o)
            if 'Contents' in response:
                objects_to_remove_path +=  [{'Key':str(i['Key'])} for i in response['Contents']]
                while len(objects_to_remove_path) > s3_del_limit:
                    client.delete_objects(Bucket=bucket, Delete={ 'Objects': objects_to_remove_path[:s3_del_limit] })
                    del objects_to_remove_path[:s3_del_limit]
                client.delete_objects(Bucket=bucket, Delete={ 'Objects': objects_to_remove_path })
                del objects_to_remove_path[:]
            else:
                print(("Error reading list response during delete of %s"%o))
                pprint.pprint(response)


def version_sort_value(v):
    if isinstance(v, int ):
        return v
    else:
        return sum([int(x) for x in v.split('.')])

def filter_stable_packages(package, files):
    stable_versions_by_package = get_stable_versions_by_package()
    if package == 'hipchat-me':
        #allow any version which matches a stable jitsi-meet version to pass
        files = [file for file in files if file['raw_version'].split('.')[0] not in stable_versions_by_package['jitsi-meet']]
    elif package == 'banana-video':
        #allow any version which matches a stable jitsi-meet version to pass
        files = [file for file in files if file['raw_version'].split('.')[0] not in stable_versions_by_package['jitsi-meet']]
    else:
        #filter the list for only those versions not in the stable list
        files = [file for file in files if str(file['raw_version']) not in stable_versions_by_package[package]]

    return files

def version_from_image_name(image_name,name_filter):
   image_pieces=image_name.split('-')
   if image_pieces[0] ==name_filter:
       base=image_pieces.pop(0)
   del image_pieces[-1]
   version='-'.join(map(str,image_pieces))
   return version

def image_data_from_image_obj(image):
    if hasattr(image,'new_tags'):
        image_tags = dict([(x['Key'], x['Value']) for x in image.new_tags])
    else:
        image_tags = dict([(x['Key'], x['Value']) for x in image.tags or []])

    return {'image_ts': image.creation_date, 
            'image_epoch_ts':image_tags.get('TS'), 
            'image_type':image_tags.get('Type'),
            'image_version':image_tags.get('Version'),
            'image_architecture':image.architecture,
            'image_build':image_tags.get('build_id'), 
            'image_name': image_tags.get('Version'), 
            'image_id': image.id,
            'image_status': image.state
        }

def get_image_list(ec2, name_filter,version='latest',architecture='x86_64'):
    filters=[{'Name':'tag:Type','Values':[name_filter]}]
    if version != 'latest':
        filters.append({'Name': 'tag:Version', 'Values': [version]})

    if architecture:
        filters.append({'Name': 'architecture', 'Values': [architecture]})

    jvb_images = ec2.images.filter(Owners=['self'],Filters=filters)
    # image_tags = {}

    images_by_ts = []
    for image in jvb_images:
       images_by_ts.append(image_data_from_image_obj(image))

    images_by_ts=sorted(images_by_ts,key=lambda timg: timg['image_ts'], reverse=True)
    return images_by_ts

def print_image_list(images):
    print_table('Type')
    print_table('Version')
    print_table('Architecture')
    print_table('Timestamp')
    print_table('AMI ID')
    print_table('Status')
    print('')
    print(('-' * (width * 5)))
    for image in images:    
        print_table(str(image['image_type']))
        print_table(str(image['image_version']))
        print_table(str(image['image_architecture']))
        print_table(str(image['image_ts']))
        print_table(str(image['image_id']))
        print_table(str(image['image_status']))
        print('')

def extract_ip_address(instance):
    if instance.public_ip_address:
        return instance.public_ip_address
    else:
        return instance.private_ip_address

def print_table(item):
    print("{}|".format(item.ljust(width),item.ljust(width)), end='')

def print_signal_instance(instance):
    print_table(instance.id)
    print_table(instance.region)
    if not (instance.public_ip_address is None):
        print_table(instance.public_ip_address)
    else:
        print_table('')
    print_table(instance.private_ip_address)
    # name is printed before autoscale group name
    print_table(extract_tag(instance.tags,SHARD_TAG))
    print_table(extract_tag(instance.tags,SHARD_STATE_TAG))
    print_table(extract_tag(instance.tags,SHARD_TESTED_TAG))

    print('')

def print_signal_Instances(instances):
    instances=sorted(instances,key=lambda instance: (extract_tag(instance.tags,SHARD_TAG)[-1],instance.region,instance.private_ip_address), reverse=False)
    print_table('Instance ID')
    print_table('Region')
    print_table('Public IP address')
    print_table('Private IP address')
    print_table('Shard')
    print_table('State')
    print_table('Tested')
    print('')
    print(('-' * (width * 6)))
    for instance in instances:
        print_signal_instance(instance)


def print_Instance(instance):
    print_table(instance.id)
    print_table(instance.region)
    if not (instance.public_ip_address is None):
        print_table(instance.public_ip_address)
    else:
        print_table('')
    if not (instance.private_ip_address is None):
        print_table(instance.private_ip_address)
    else:
        print_table('')
    # name is printed before autoscale group name
    print_table(extract_tag(instance.tags,SHARD_TAG))
    print_table(instance.provider)

    print('')

def print_Instances(instances):
    instances=sorted(instances,key=lambda instance: (extract_tag(instance.tags,SHARD_TAG)[-1] if extract_tag(instance.tags,SHARD_TAG) else 0, instance.region,instance.private_ip_address), reverse=False)
    print_table('Instance ID')
    print_table('Region')
    print_table('Public IP address')
    print_table('Private IP address')
    print_table('Shard')
    print_table('Provider')
    print('')
    print(('-' * (width * 6)))
    for instance in instances:
        print_Instance(instance)

def print_jibri_Instances(instances):
    instances=sorted(instances,key=lambda instance: extract_tag(instance.tags,ENVIRONMENT_TAG), reverse=False)
    print_table('Instance ID')
    print_table('Region')
    print_table('Public IP address')
    print_table('Private IP address')
    print_table('Name')
    print('')
    print(('-' * (width * 6)))
    for instance in instances:
        print_table(instance.id)
        print_table(instance.region)
        if not (instance.public_ip_address is None):
            print_table(instance.public_ip_address)
        else:
            print_table('')
        print_table(instance.private_ip_address)
        # name is printed before autoscale group name
        print_table(extract_tag(instance.tags,'Name'))
        print('')

def create_new_loadbalancer_securitygroups(region=None,environment=None):
    if region:
        regions = [region]
    else:
        regions = AWS_REGIONS

    #first pull all haproxy instances
    proxy_instances = all_haproxy_instances(environment=environment)

    #loop on all haproxies to build list of environments and regions/clouds for which to create an LB group
    region_vpc_environments = {}
    instances_by_vpc_environment = {}
    instances_by_environment = {}
    haproxy_stack_by_vpc_environment = {}
    prefix_by_vpc = {}

    for p in proxy_instances:
        environment = [t for t in p.tags if t['Key'] == ENVIRONMENT_TAG][0]['Value']
        haproxy_stack = [t for t in p.tags if t['Key'] == 'aws:cloudformation:stack-name'][0]['Value']
        cloud_prefix = haproxy_stack.split('-')[-2]
        prefix_by_vpc[p.vpc_id] = cloud_prefix
        print(('Proxy: %s Env: %s VPC: %s'%(p,environment,p.vpc_id)))
        if p.vpc_id not in instances_by_vpc_environment:
            print(('initializing VPC %s in instance list'%p.vpc_id))
            instances_by_vpc_environment[p.vpc_id] = {}

        if environment not in instances_by_vpc_environment[p.vpc_id]:
            print(('initializing environment %s in VPC %s instance list'%(environment,p.vpc_id)))
            instances_by_vpc_environment[p.vpc_id][environment] = []

        if p.vpc_id not in list(haproxy_stack_by_vpc_environment.keys()):
            haproxy_stack_by_vpc_environment[p.vpc_id] = {}

        if environment not in list(instances_by_environment.keys()):
            instances_by_environment[environment] = []

        haproxy_stack_by_vpc_environment[p.vpc_id][environment] = haproxy_stack

        instances_by_vpc_environment[p.vpc_id][environment].append(p)
        instances_by_environment[environment].append(p)

        print('Instances by VPC Environment during loop')
        pprint.pprint(instances_by_vpc_environment)

#        print('Stack %s prefix %s'%(haproxy_stack,cloud_prefix))
#        pprint.pprint(p.tags)
        region = p.region
        if not region in region_vpc_environments:
            region_vpc_environments[region] = {}
        if not p.vpc_id in region_vpc_environments[region]:
            region_vpc_environments[region][p.vpc_id] = set([environment])
        else:
            region_vpc_environments[region][p.vpc_id].add(environment)


    print('Instances by VPC Environment after loop')
    pprint.pprint(instances_by_vpc_environment)

    #now find the haproxy stack for each region/environment combination
    for region in regions:
        if region in region_vpc_environments:
            for vpc in region_vpc_environments[region]:
                for environment in region_vpc_environments[region][vpc]:
                    #try to find an existing security group matching the criteria
                    sgs = find_securitygroups('haproxy',environment=environment,region=region,vpc_id=vpc)
                    if len(sgs) > 0:
                        print(('Security Group Found: %s %s %s'%(region, vpc, environment)))
                        sg = sgs[0]
                        lb_cidrs = [ '%s/32'%i.public_ip_address for i in instances_by_environment[environment] ]
                        apply_security_group_cidrs(sg, lb_cidrs, port=1024)
                    else:
                        print(('Security Group Not Found, creating: %s %s %s'%(region, vpc, environment)))
                        nstack = get_cloud_network_stack(region=region,cloud_prefix=prefix_by_vpc[vpc])
                        ssh_group_id=get_network_ssh_securitygroup(nstack)
                        elb=find_elb_from_stack_name(haproxy_stack_by_vpc_environment[vpc][environment],region=region)
                        elb_group_id=elb['SecurityGroups'][0]
                        new_sg = create_lb_security_group(region, vpc_id=vpc, environment=environment, prefix=prefix_by_vpc[vpc], ssh_group_id=ssh_group_id, elb_group_id=elb_group_id)
                        lb_cidrs = [ '%s/32'%i.public_ip_address for i in instances_by_environment[environment] ]
                        apply_security_group_cidrs(new_sg, lb_cidrs, port=1024)
    #                    response=add_sg_to_elb(elb,sg=new_sg)
                        response=add_sg_to_instances(instances=instances_by_vpc_environment[vpc][environment],sg=new_sg)


def fix_haproxy_elb_connection_draining(environment, region=False):
    proxy_instances = all_haproxy_instances_with_elbs(environment=environment, region=region)
    elbs = {}
    for p in proxy_instances:
        elbs[p.elb['LoadBalancerName']] = p.elb

    update_elbs_by_region={}
    for elb_name in elbs:
        if elbs[elb_name]['LoadBalancerAttributes']['ConnectionDraining']['Enabled']:
            print(('ELB ConnectionDraining OK: %s'%elb_name))
        else:
            print(('ELB ConnectionDraining FAIL: %s'%elb_name))
            if elbs[elb_name]['Region'] not in update_elbs_by_region:
                update_elbs_by_region[elbs[elb_name]['Region']] = []
            if not elb_name in update_elbs_by_region[elbs[elb_name]['Region']]:
                update_elbs_by_region[elbs[elb_name]['Region']].append(elb_name)

        if elbs[elb_name]['LoadBalancerAttributes']['ConnectionDraining']['Timeout'] == 90:
            print(('ELB Draining Timeout OK: %s'%elb_name))
        else:
            print(('ELB Draining Timeout FAIL: %s (%s != %s)'%(elb_name,elbs[elb_name]['LoadBalancerAttributes']['ConnectionDraining']['Timeout'],90)))
            if elbs[elb_name]['Region'] not in update_elbs_by_region:
                update_elbs_by_region[elbs[elb_name]['Region']] = []
            if not elb_name in update_elbs_by_region[elbs[elb_name]['Region']]:
                update_elbs_by_region[elbs[elb_name]['Region']].append(elb_name)

        if elbs[elb_name]['LoadBalancerAttributes']['ConnectionSettings']['IdleTimeout'] == 90:
            print(('ELB Idle Timeout OK: %s'%elb_name))
        else:
            print(('ELB Idle Timeout FAIL: %s (%s != %s)'%(elb_name,elbs[elb_name]['LoadBalancerAttributes']['ConnectionSettings']['IdleTimeout'],90)))
            if elbs[elb_name]['Region'] not in update_elbs_by_region:
                update_elbs_by_region[elbs[elb_name]['Region']] = []
            if not elb_name in update_elbs_by_region[elbs[elb_name]['Region']]:
                update_elbs_by_region[elbs[elb_name]['Region']].append(elb_name)


    overall_success = True
    for elb_region in update_elbs_by_region:
        elb = boto3.client('elb', region_name=elb_region)
        for elb_name in update_elbs_by_region[elb_region]:
            #start with the old attributes
            lb_attributes = elbs[elb_name]['LoadBalancerAttributes']
            #enable ConnectionDraining and set the timeout to 90
            lb_attributes['ConnectionDraining']['Timeout'] = 90
            lb_attributes['ConnectionDraining']['Enabled'] = True
            lb_attributes['ConnectionSettings']['IdleTimeout'] = 90
            response=elb.modify_load_balancer_attributes(LoadBalancerName=elb_name, LoadBalancerAttributes=lb_attributes)

            if not response or 'ResponseMetadata' not in response or response['ResponseMetadata']['HTTPStatusCode'] != 200:
                print("ELB attributes failed to be updated")
                pprint.pprint(response)
                overall_success=False
            else:
                print(("ELB %s attributes updated successfully"%elb_name))

    return overall_success

def elbs_by_environment(environment,region=False):
    out_elbs={}
    descriptions_and_tags = get_elb_descriptions_and_tags(region)
    for elb_name in descriptions_and_tags:
        elb_environment = extract_tag(descriptions_and_tags[elb_name]['Tags'],'environment')
        if elb_environment == environment:
            out_elbs[elb_name] = descriptions_and_tags[elb_name]

    return out_elbs

def albs_by_environment(environment,region=False):
    out_albs={}
    descriptions_and_tags = get_alb_descriptions_and_tags(region)
    for alb_arn in descriptions_and_tags:
        elb_environment = extract_tag(descriptions_and_tags[alb_arn]['Tags'],'environment')
        if elb_environment == environment:
            out_albs[alb_arn] = descriptions_and_tags[alb_arn]

    return out_albs

def environment_elb_health(environment, region=False):
    elbs=elbs_by_environment(environment,region)
    health_by_elb = {}
    for elb_name in elbs:
        instance_health = elb_instance_health(elb_name, elbs[elb_name]['Region'])
        health_by_elb[elb_name] = instance_health

    return health_by_elb

def elb_instance_health(elb, region=False):        
    client = boto3.client('elb', region_name=region)
    response = client.describe_instance_health(
        LoadBalancerName=elb
    )
    return response


def environment_alb_health(environment, region=False, role=False):
    albs=albs_by_environment(environment,region)
    health_by_alb = {}
    for alb_arn in albs:
        include_alb=True
        if role:
            # filter by role if provided
            include_alb=False
            alb_role = extract_tag(albs[alb_arn]['Tags'],'stack-role')
            if alb_role == role:
                include_alb=True
        if include_alb:
            instance_health = alb_instance_health(albs[alb_arn], albs[alb_arn]['Region'])
            health_by_alb[alb_arn] = instance_health

    return health_by_alb

def alb_instance_health(alb, region=False):
    responses = []
    client = boto3.client('elbv2', region_name=region)

    alb_tgs = client.describe_target_groups(
        LoadBalancerArn=alb['LoadBalancerArn']
    )

    for tg in alb_tgs['TargetGroups']:
        response = client.describe_target_health(
            TargetGroupArn=tg['TargetGroupArn'],
        )
        responses.append(response)

    return responses

def all_haproxy_instances_with_elbs(environment, shard_role=False, region=False):

    proxies_by_stack = {}
    #first pull all haproxy instances in the environment
    proxy_instances = all_haproxy_instances(environment=environment,shard_role=shard_role,region=region)

    return_instances = []
    #split them by stack
    for p in proxy_instances:
        haproxy_stack = extract_tag(p.tags,'aws:cloudformation:stack-name')
        p.haproxy_stack = haproxy_stack
        if not haproxy_stack in proxies_by_stack:
            proxies_by_stack[haproxy_stack] = []
        proxies_by_stack[haproxy_stack].append(p)

    descriptions_and_tags_elb = get_elb_descriptions_and_tags(region=region)
    descriptions_and_tags_alb = get_alb_descriptions_and_tags(region=region)

    for stack in proxies_by_stack:
        elb=find_elb_from_stack_name(stack, region, descriptions_and_tags=descriptions_and_tags_elb)
        alb=find_alb_from_stack_name(stack, region, descriptions_and_tags=descriptions_and_tags_alb)
        for p in proxies_by_stack[stack]:
            p.elb = elb
            p.alb = alb
            return_instances.append(p)

    return return_instances


def remove_instances_from_elb(elb, instances, region=None, elb_type='elb'):
    if not region:
        for instance in instances:
            region=instance.region

    if elb_type == 'elb':
        instance_objs = []

        for instance in instances:
            instance_objs.append({'InstanceId': instance.id})

        client = boto3.client('elb', region_name=region)
        response = client.deregister_instances_from_load_balancer(
            LoadBalancerName=elb['LoadBalancerName'],
            Instances=instance_objs
        )
    elif elb_type == 'elbv2':
        client = boto3.client('elbv2', region_name=region)

        alb_tgs = client.describe_target_groups(
            LoadBalancerArn=elb['LoadBalancerArn']
        )

        response = remove_instances_from_tgs([ tg['TargetGroupArn'] for tg in alb_tgs['TargetGroups']], instances, region)


#    response = {'LoadBalanceName': elb['LoadBalancerName'], 'Instances':instance_objs, 'action':'remove'}
    return response



def get_target_groups_from_for_alb(alb, region=None):
        client = boto3.client('elbv2', region_name=region)

        alb_tgs = client.describe_target_groups(
           LoadBalancerArn=elb['LoadBalancerArn']
        )

        return alb_tgs['TargetGroups']

def get_stack_details(stack_name, region=None):
    client = boto3.client('cloudformation', region_name=region)

    response = client.describe_stacks(
        StackName=stack_name
    )

    if 'Stacks' in response and len(response['Stacks']) > 0:
        return response['Stacks'][0]
    else:
        return False

def alb_from_stack_details(stack_details):
    return output_by_key(stack_details['Outputs'], 'ALB')

def get_target_groups_from_stack_details(stack_details):
    tg_str = output_by_key(stack_details['Outputs'], 'TargetGroups')
    if tg_str:
        return tg_str.split(',')
    return None

def output_by_key(outputs, key):
    item=next(filter(lambda o: o['OutputKey'] == key, outputs), None)
    if item:
        return item['OutputValue']
    return None



def set_target_groups_in_alb(alb_arn, target_groups, region=None):
        client = boto3.client('elbv2', region_name=region)

        alb_listeners = client.describe_listeners(
           LoadBalancerArn=alb_arn
        )

        ssl_listener = [item for item in alb_listeners['Listeners'] if item["Port"] == 443][0]
        if ssl_listener:
            new_action =  ssl_listener['DefaultActions'][0]
            new_tgs = [ {'TargetGroupArn': tg, 'Weight': 1} for tg in target_groups ]
            if set(target_groups) == set([ x['TargetGroupArn'] for x in new_action['ForwardConfig']['TargetGroups']]):
                print('TG lists match, taking no action')
                return False
            else:
                new_action['ForwardConfig']['TargetGroups'] = new_tgs

                response=client.modify_listener(
                    ListenerArn=ssl_listener['ListenerArn'],
                    DefaultActions=[new_action]
                )

                if 'ResponseMetadata' in response and response['ResponseMetadata']['HTTPStatusCode'] == 200:
                    return True
                else:
                    pprint.pprint(response)
                    return False

        else:
            # error here?
            return False

def remove_instances_from_tgs(tgs, instances, region):
    instance_objs = []

    for instance in instances:
        instance_objs.append({'Id': instance.id})

    client = boto3.client('elbv2', region_name=region)
    responses=[]
    for tg in tgs:
        responses.append(client.deregister_targets(
            TargetGroupArn=tg,
            Targets=instance_objs
        ))
    return responses

def add_instances_to_tgs(tgs, instances, region):
    instance_objs = []

    for instance in instances:
        instance_objs.append({'Id': instance.id})


    client = boto3.client('elbv2', region_name=region)
    responses=[]
    for tg in tgs:
        responses.append(client.register_targets(
            TargetGroupArn=tg,
            Targets=instance_objs
        ))
    return responses

def add_instances_to_elb(elb, instances, region=None, elb_type='elb'):
    response = False
    if not region:
        for instance in instances:
            region=instance.region

    if elb_type == 'elb':
        instance_objs = []

        for instance in instances:
            instance_objs.append({'InstanceId': instance.id})

        client = boto3.client('elb', region_name=region)
        response = client.register_instances_with_load_balancer(
            LoadBalancerName=elb['LoadBalancerName'],
            Instances=instance_objs
        )
    elif elb_type == 'elbv2':
        client = boto3.client('elbv2', region_name=region)

        alb_tgs = client.describe_target_groups(
           LoadBalancerArn=elb['LoadBalancerArn']
        )

        response = add_instances_to_tgs([ tg['TargetGroupArn'] for tg in alb_tgs['TargetGroups']], instances, region)

#    response = {'LoadBalanceName': elb['LoadBalancerName'], 'Instances':instance_objs, 'action':'add'}
    return response

def add_sg_to_elb(elb, sg, region=None):
    if not region:
        region=AWS_DEFAULT_REGION

    client = boto3.client('elb', region_name=region)
    new_groups = set(elb['SecurityGroups'])
    new_groups.add(sg.group_id)
    response = client.apply_security_groups_to_load_balancer(
        LoadBalancerName=elb['LoadBalancerName'],
        SecurityGroups=new_groups
    )    

def get_elb_descriptions_and_tags(region=None):
    if region:
        regions = [region]
    else:
        regions = AWS_REGIONS

    descriptions_by_name = {}

    for region in regions:
        elb = boto3.client('elb', region_name=region)
        e = elb.describe_load_balancers(PageSize=100)
        elb_names = []
        for lb in e['LoadBalancerDescriptions']:
            elb_names.append(lb['LoadBalancerName'])
            lb_attributes = elb.describe_load_balancer_attributes(LoadBalancerName=lb['LoadBalancerName'])
            lb['Region'] = region
            lb.update(lb_attributes)
            descriptions_by_name[lb['LoadBalancerName']] = lb

        if len(elb_names) >0:
            chunk_size = 20            
            # using list comprehension  
            chunked_elb_names = [elb_names[i:i + chunk_size] for i in range(0, len(elb_names), chunk_size)]  

            for x in chunked_elb_names:
                tags = elb.describe_tags(LoadBalancerNames=x)
                tag_values = tags['TagDescriptions']
                for lb in tag_values:
                    descriptions_by_name[lb['LoadBalancerName']]['Tags'] = lb['Tags']

    return descriptions_by_name

def chunks(lst, n):
    """Yield successive n-sized chunks from lst."""
    for i in range(0, len(lst), n):
        yield lst[i:i + n]

def get_alb_descriptions_and_tags(region=None):
    if region:
        regions = [region]
    else:
        regions = AWS_REGIONS

    descriptions_by_arn = {}

    for region in regions:
        alb = boto3.client('elbv2', region_name=region)
        e = alb.describe_load_balancers(PageSize=100)
        alb_arns = []

        for lb in e['LoadBalancers']:
            alb_arns.append(lb['LoadBalancerArn'])
            lb_attributes = alb.describe_load_balancer_attributes(LoadBalancerArn=lb['LoadBalancerArn'])
            lb['Region'] = region
            lb.update(lb_attributes)
            descriptions_by_arn[lb['LoadBalancerArn']] = lb

        if len(alb_arns) >0:
            for chunk in chunks(alb_arns,20):
                tags = alb.describe_tags(ResourceArns=chunk)
                tag_values = tags['TagDescriptions']
                for lb in tag_values:
                    descriptions_by_arn[lb['ResourceArn']]['Tags'] = lb['Tags']

    return descriptions_by_arn

def find_elb_from_stack_name(stack_name,region=None, descriptions_and_tags=None):
    if region:
        regions = [region]
    else:
        regions = AWS_REGIONS

    if not descriptions_and_tags:
        descriptions_and_tags = get_elb_descriptions_and_tags(region=region)

    for elb_name in descriptions_and_tags:
        elb_stack_name = extract_tag(descriptions_and_tags[elb_name]['Tags'],'aws:cloudformation:stack-name')
        if elb_stack_name == stack_name:
            return descriptions_and_tags[elb_name]

def find_alb_from_stack_name(stack_name,region=None, descriptions_and_tags=None):
    if region:
        regions = [region]
    else:
        regions = AWS_REGIONS

    if not descriptions_and_tags:
        descriptions_and_tags = get_alb_descriptions_and_tags(region=region)

    for alb_name in descriptions_and_tags:
        alb_stack_name = extract_tag(descriptions_and_tags[alb_name]['Tags'],'cf_stack_name')
        if stack_name.endswith('baron-haproxy'):
            stack_name=stack_name.replace('baron-haproxy','haproxy')

        if alb_stack_name == stack_name:
            return descriptions_and_tags[alb_name]

    print(("failed to find ALB for stack %s"%stack_name))


def add_sg_to_instances(instances, sg):
    pprint.pprint(instances)
    responses = []
    for instance in instances:
        groups = [ x['GroupId'] for x in instance.security_groups]
        groups.append(sg.group_id)
        response = instance.modify_attribute(Groups=groups)
        responses.append(response)

    return responses

def create_lb_security_group(region, vpc_id, environment, prefix='aws1', ssh_group_id=None, elb_group_id=None):
    ec2 = boto3.resource('ec2',region_name=region)
    vpc = ec2.Vpc(vpc_id)
    group_name = '%s-%s-%s-LBGroup'%(environment,region,prefix)
    desc = "Load Balancer Nodes %s %s %s"%(environment,region,prefix)
    sg = vpc.create_security_group(GroupName=group_name,Description=desc)
    sleep(10)
    tags = []
    tags.append({'Key':'Name','Value':group_name})
    tags.append({'Key':'environment','Value':environment})
    tags.append({'Key':'role','Value':'haproxy'})
    tags.append({'Key':'Environment','Value':'dev'})
    tags.append({'Key':'Product','Value':'meetings'})
    tags.append({'Key':'Owner','Value':'Meetings'})
    tags.append({'Key':'Team','Value':'meet@8x8.com'})
    tags.append({'Key':'Service','Value':'jitsi-haproxy-sg'})
    sg.create_tags(Tags=tags)
    ipPermissions = [
                {
                    'IpProtocol':'tcp',
                    'FromPort':1024,
                    'ToPort':1024,
                    'UserIdGroupPairs':[{
                        'GroupId': sg.group_id,
                    }]
                },
                {
                    'IpProtocol':'tcp',
                    'FromPort':8080,
                    'ToPort':8080,
                    'UserIdGroupPairs':[{
                        'GroupId': sg.group_id,
                    }]
                },
                {
                    'IpProtocol':'tcp',
                    'FromPort':443,
                    'ToPort':443,
                    "IpRanges": [{"CidrIp": "0.0.0.0/0"}]
                },
                {
                    'IpProtocol':'tcp',
                    'FromPort':80,
                    'ToPort':80,
                    "IpRanges": [{"CidrIp": "0.0.0.0/0"}]
                }
            ]

    if elb_group_id:
        ipPermissions.append({
                    'IpProtocol':'tcp',
                    'FromPort':8080,
                    'ToPort':8080,
                    'UserIdGroupPairs':[{
                        'GroupId': elb_group_id,
                    }]
                })

    if ssh_group_id:
        ipPermissions.append({
                    'IpProtocol':'tcp',
                    'FromPort':22,
                    'ToPort':22,
                    'UserIdGroupPairs':[{
                        'GroupId': ssh_group_id,
                    }]
                })

    try:
        sg.authorize_ingress(IpPermissions = ipPermissions)
    except ClientError as e:
        print('Exception occurred authorizing ingress')
        pprint.pprint(e)

    return sg


def get_all_vpcs(region=None):
    if hcv_debug: print((inspect.currentframe().f_code.co_name))
    global AWS_REGIONS
    if not region:
        regions = AWS_REGIONS
    else:
        regions = [region]

    out_vpcs={}
    for region in regions:
        client = boto3.client('ec2', region_name=region)
        try:
            vpc_response = client.describe_vpcs()
            for vpc in vpc_response['Vpcs']:
                vpc['Region'] = region
                out_vpcs[vpc['VpcId']] = vpc
        except:
            e = sys.exc_info()[0]
            print(("Exception getting VPCS in region %s: %s"%(region,e)))
            pprint.pprint(e)

    return out_vpcs

def find_securitygroups(role,environment=None,region=None,vpc_id=None):
    out_groups = []
    if not region:
        regions = AWS_REGIONS
    else:
        regions = [region]

    for region in regions:
        ec2 = boto3.resource('ec2',region_name=region)
        sgs = ec2.security_groups.all()
        for g in sgs:
            if vpc_id:
                if vpc_id != g.vpc_id:
                    #didn't match the VPC, so skip this group
                    continue
            if g.tags and len(g.tags)>0:
                #append region to sg
                g.region=region
                if environment:
                    t = [t for t in g.tags if t['Key'] == ENVIRONMENT_TAG]
                    #no environment tag, or didn't match environment, so skip
                    if not t or t[0]['Value'] != environment:
                        continue

                #make sure we match the role
                t = [t for t in g.tags if t['Key'] == 'role']
                if t and t[0]['Value'] == role:
                    out_groups.append(g)

    return out_groups




def apply_security_group_cidrs(sg, cidrs, port=1024, DryRun=False):
    items = [i for i in sg.ip_permissions if i['IpProtocol'] == 'tcp' and i['FromPort'] == port and i['ToPort'] == port]
    if len(items):
        sg_cidrs = [ r['CidrIp'] for r in items[0]['IpRanges'] ]

        print(('Existing CIDRS for security group %s:'%sg.group_id))
        pprint.pprint(sg_cidrs)

        print(('Incoming CIDRS for security group %s:'%sg.group_id))
        pprint.pprint(cidrs)

        #make sure we have an entry for every LB IP
        add_new_list = [ cidr for cidr in cidrs if cidr not in sg_cidrs ]
        remove_set = set(sg_cidrs) - set(cidrs)
    else:
        #no items found for port, so need to add all
        add_new_list = cidrs
        remove_set = []


    #now handle adding any new items
    if len(add_new_list) > 0:
        add_ranges = [{'CidrIp':cidr} for cidr in add_new_list]
        print(('Adding ranges to security group %s:'%sg.group_id))
        pprint.pprint(add_ranges)
        try:
            sg.authorize_ingress(DryRun=DryRun,
                IpPermissions = [
                    {
                        'IpProtocol':'tcp',
                        'FromPort':1024,
                        'ToPort':1024,
                        'IpRanges': add_ranges
                    }
                ]
            )
        except ClientError as e:
            print('Exception occurred authorizing ingress')
            pprint.pprint(e)

    #now remove any deprecated items
    if len(remove_set) > 0:
        remove_ranges = [{'CidrIp':cidr} for cidr in remove_set]
        print('Removing ranges from security group:')
        pprint.pprint(remove_ranges)
        try:
            sg.revoke_ingress(DryRun=DryRun,
                IpPermissions = [
                    {
                        'IpProtocol':'tcp',
                        'FromPort':1024,
                        'ToPort':1024,
                        'IpRanges': remove_ranges
                    }
                ]
            )
        except ClientError as e:
            print('Exception occurred revoking ingress')
            pprint.pprint(e)    


def update_loadbalancer_securitygroups(environment,region=None):

    #first pull all haproxy instances
    proxy_instances = all_haproxy_instances(environment=environment)

    #find all security groups with appropriate tags
    lb_sgs = find_securitygroups('haproxy',environment=environment)

    lb_cidrs = [ '%s/32'%i.public_ip_address for i in proxy_instances ]

#    pprint.pprint(lb_public_ips)
    #now confirm that an entry exists for each lb public IP in each sg
    for sg in lb_sgs:
        apply_security_group_cidrs(sg, lb_cidrs, port=1024)

def get_region_alias(region):
    if region=='ap-southeast-2':
        return 'ap-se-2'
    if region=='ap-southeast-1':
        return 'ap-se-1'

    return region


def get_cloud_network_stack(region,cloud_prefix):
    cf=boto3.resource('cloudformation',region_name=region)
    region_alias = get_region_alias(region)
    net_stack = cf.Stack('%s-%s-network'%(region_alias,cloud_prefix))
    return net_stack

def get_region_loadbalancer_securitygroup(net_stack):
    sg_id=[t for t in net_stack.outputs if t['OutputKey'] == 'LBSecurityGroup'][0]['OutputValue']
    return sg_id

def get_network_ssh_securitygroup(net_stack):
    sg_id=[t for t in net_stack.outputs if t['OutputKey'] == 'SSHSecurityGroup'][0]['OutputValue']
    return sg_id

def all_loadbalancer_securitygroups():
    all_sgs = []
    for region in AWS_REGIONS:
        net_stack = get_region_network_stack(region)
        sg_id = get_region_loadbalancer_securitygroup(net_stack)

        ec2 = boto3.resource('ec2',region_name=region)
        sg = ec2.SecurityGroup(sg_id)
        all_sgs.append(sg)

    return all_sgs

def all_haproxy_instances(environment=None, shard_role=False, region=False):
    if not shard_role:
        shard_role=SHARD_HAPROXY_ROLE

    all_haproxy_instances =  get_instances_by_role(role_name=shard_role,environment_name=environment, region=region)

    return all_haproxy_instances

def print_haproxy_Instances(instances):
    instances=sorted(instances,key=lambda instance: (instance.region,extract_tag(instance.tags,'Name')), reverse=False)
    print_table('Instance ID')
    print_table('Region')
    print_table('Public IP address')
    print_table('Private IP address')
    print_table('Name')
    print('')
    print(('-' * (width * 6)))
    for instance in instances:
        print_table(instance.id)
        print_table(instance.region)
        if not (instance.public_ip_address is None):
            print_table(instance.public_ip_address)
        else:
            print_table('')
        print_table(instance.private_ip_address)

        print_table(extract_tag(instance.tags,'Name'))

        print('')


def get_shard_stacks(environment=None,shard=None,region=None):
    if region:
        regions = [region]
    else:
        regions = AWS_REGIONS

    out_stacks = []
    for region_name in regions:
        cf = boto3.resource('cloudformation', region_name=region_name)
        stacks = cf.stacks.all();
        for stack in stacks:
            #specify the region in case we're going to pass this stack along
            stack.region=region_name
            #pull out the shard and environment tags from the stack
            stack_shard = extract_tag(stack.tags,SHARD_TAG)
            stack_environment = extract_tag(stack.tags,ENVIRONMENT_TAG)
            #shard tag is provided, so we've found a stack that's also a shard
            if stack_shard:
                if shard:
                    #a shard value has been provided so filter on it preferrentially
                    if stack_shard==shard:
                        #found our match!
                        out_stacks.append(stack)
                        return out_stacks
                else:
                    #no shard specified, so just look for any in the environment
                    if not environment or (environment==stack_environment):
                        out_stacks.append(stack)

    return out_stacks

def get_cloudformation_by_stack_role(role='network'):
    out_stacks = []
    for region in AWS_REGIONS:
        cf = boto3.resource('cloudformation', region_name=region)
        stacks = cf.stacks.all();
        for stack in stacks:
            stack_role = extract_tag(stack.tags,STACK_ROLE_TAG)
            if stack_role == role:
                stack.region=region
                out_stacks.append(stack)

    return out_stacks


def get_cloudformation_by_environment(environment):
    out_stacks = []
    for region in AWS_REGIONS:
        cf = boto3.resource('cloudformation', region_name=region)
        stacks = cf.stacks.all();
        for stack in stacks:
            stack_environment = extract_tag(stack.tags,ENVIRONMENT_TAG)
            if stack_environment == environment:
                out_stacks.append(stack)
            elif stack.name.startswith(environment):
                out_stacks.append(stack)
            elif stack.name.startswith(environment.replace('hipchat','')):
                out_stacks.append(stack)

    return out_stacks

def fix_stack_name(stack_name):
    return stack_name.replace('-us-east1a','').replace('-us-east1b','').replace('-us-east-1a','').replace('-us-east-1b','').replace('-us-west2a','').replace('-us-west2b','').replace('-us-west-2a','').replace('-us-west-2b','').replace('-shard','-s')

def get_cloudformation_by_release(environment,release_number, region=None, cloud_provider=None):
    if not region:
        regions=AWS_REGIONS
    else:
        regions=[region]

    out_stacks = []
    for ec2_region in regions:
        cf = boto3.resource('cloudformation', region_name=ec2_region)

        stacks = cf.stacks.all();
        added_stack = False
        for stack in stacks:
            re = extract_tag(stack.tags,ENVIRONMENT_TAG)
            if re == environment:
                rn = extract_tag(stack.tags,RELEASE_NUMBER_TAG)
                if rn == release_number:
                    cp = extract_tag(stack.tags,CLOUD_PROVIDER_TAG)
                    if not cp:
                        cp = 'aws'
                    if not cloud_provider or cp == cloud_provider:
                        out_stacks.append(stack)

    return out_stacks

def terminate_jvb_instances_by_stack(stack_name, region=None):
    asg = boto3.client('autoscaling', region_name=region)
    ec2 = boto3.client('ec2',region_name=region)

    jvb_asg_name = get_jvb_autoscaling_group_name_by_stack(stack_name, region=region)
    if jvb_asg_name:
        asg.update_auto_scaling_group(AutoScalingGroupName=jvb_asg_name,MinSize=0)
        asg_desc = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[jvb_asg_name])
        if 'AutoScalingGroups' in asg_desc:
            jvb_instances = asg_desc['AutoScalingGroups'][0]['Instances']
            instance_ids = [ i['InstanceId'] for i in jvb_instances ]
            response = asg.detach_instances(
                InstanceIds=instance_ids,
                AutoScalingGroupName=jvb_asg_name,
                ShouldDecrementDesiredCapacity=True
            )
            ec2.terminate_instances(InstanceIds=instance_ids)

            response = asg.delete_auto_scaling_group(
                AutoScalingGroupName=jvb_asg_name,
                ForceDelete=True
            )
    else:
        print('ERROR: No JVB asg name found, not terminating JVBs for stack %s'%stack_name)


def wait_stack_delete_complete(stack_name, region=None):
    cf = boto3.client('cloudformation', region_name=region)
    while True:
        try:
            response = cf.describe_stacks(StackName=stack_name)
            if (not 'Stacks' in response) or (len(response['Stacks']) == 0):
                return True;
            else:
                # still in the list, so wait and continue
                print("waiting on stack %s delete, current state %s"%(stack_name,response['Stacks'][0]['StackStatus']))
                sleep(300)
        except:
            return True


def get_jvb_autoscaling_group_name_by_stack(stack_name, region=None):
    if not region:
        regions=AWS_REGIONS
    else:
        regions=[region]        

    out_stacks = []
    for ec2_region in regions:
        cf = boto3.resource('cloudformation', region_name=ec2_region)

        stack_resource = cf.StackResource(stack_name,'JVBAutoScaleGroup')
        if stack_resource:
            return stack_resource.physical_resource_id
        else:
            return None

def find_asg_by_tags(region,environment,role=False,grid=False,grid_role=False,release_number=False,cloud_provider=False,shard=False):
    if not isinstance(region,list):
        region = [region]
    out_asg=[]
    for r in region:
        asg = boto3.client('autoscaling', region_name=r)        
        asg_desc = asg.describe_auto_scaling_groups()
        raw_asgs=asg_desc['AutoScalingGroups']
        while 'NextToken' in asg_desc:
            asg_desc = asg.describe_auto_scaling_groups(NextToken=asg_desc['NextToken'])
            raw_asgs = raw_asgs + asg_desc['AutoScalingGroups']
        ntags = []
        for group in raw_asgs:
            aetags = group['Tags']
            ae = extract_tag(aetags,'environment')
            ar = extract_tag(aetags,'shard-role')
            s = extract_tag(aetags, SHARD_TAG)
            ag = extract_tag(aetags,'grid')
            agr = extract_tag(aetags,'grid-role')
            arn = extract_tag(aetags,'release_number')
            cp = extract_tag(aetags, CLOUD_PROVIDER_TAG)
            # default cloud provider to aws if none is set
            if not cp:
                cp = 'aws'

            group['region']=r
            if ae == environment:
                if not role or (role == ar):
                    if not grid or (grid == ag):
                        if not grid_role or (grid_role == agr):
                            if not release_number or (release_number == arn):
                                if not cloud_provider or (cloud_provider == cp):
                                    if not shard or (shard == s):
                                        out_asg.append(group)
    return out_asg

def shard_region_from_name(shard_name, map_to_aws=True):
    shard_region = ''
    check_oracle_map = False
    if shard_name:
        shard_pieces = shard_name.split('-')
        shard_number = shard_pieces.pop()
        region_az = shard_pieces.pop()
        # for jvb pools the pool type comes next
        if not region_az[0].isnumeric():
            check_oracle_map = True
            region_az = shard_pieces.pop()
        region_geo = shard_pieces.pop()
        region_base = shard_pieces.pop()
        region_number = region_az[0]
        shard_region = "%s-%s-%s"%(region_base,region_geo,region_number)
        shard_region = region_from_alias(shard_region)
        if check_oracle_map and map_to_aws:
            if shard_region in ORACLE_REGION_MAP:
                shard_region = ORACLE_REGION_MAP[shard_region]

    return shard_region

def get_cloudformation_by_shard(shard_name, region=None):
    if not region:
        region = shard_region_from_name(shard_name)
        regions=[region]
    else:
        regions=[region]        

    out_stacks = []
    for ec2_region in regions:
        cf = boto3.resource('cloudformation', region_name=ec2_region)

        stacks = cf.stacks.all();
        added_stack = False
        for stack in stacks:
            if SHARD_TAG in [ t['Key'] for t in stack.tags]:
                if [t for t in stack.tags if t['Key'] == SHARD_TAG][0]['Value'] == shard_name:
                    out_stacks.append(stack)
                    added_stack = True
            if not added_stack:
                if 'Name' in [ t['Key'] for t in stack.tags]:
                    if [t for t in stack.tags if t['Key'] == 'Name'][0]['Value'] == shard_name:
                        out_stacks.append(stack)
                        added_stack = True

            if not added_stack:
                #try another way, trim down the stack now
                stack_name = fix_stack_name(stack.name)
                if stack_name == shard_name:
                    out_stacks.append(stack)
                else:
                    #finally try with full name of shard
                    if stack.name == shard_name:
                        out_stacks.append(stack)

    if len(out_stacks):
        return out_stacks[0]
    else:
        return False

def get_oracle_compartment_by_environment(environment_name,config=False):
    if not config:
        config = oci.config.from_file()

    out_compartment = None
    identity = oci.identity.IdentityClient(config)
    response = identity.list_compartments(config["tenancy"])
    for compartment in response.data:
        if compartment.name == environment_name:
            out_compartment = compartment
            break

    return out_compartment

class OracleInstance:
    def __init__(self, **entries):
        self.__dict__.update(entries)

def convert_tag_dict_to_aws_style(tags):
    aws_tags = []
    for k in tags.keys():
        aws_tags.append({'Key':k, 'Value':tags[k]})
    return aws_tags

def convert_aws_regions_to_oracle(regions):
    map = oracle_regions_by_aws()
    out_regions = [ map[r] for r in regions if r in map ]

    return out_regions

def get_oracle_image_list_by_search(type,version=False,regions=False,config=False,compartment=False):
    if not config:
        config = oci.config.from_file()
    if not compartment:
        compartment = config["tenancy"]

    if not regions:
        regions = oracle_regions()


    image_list = []
    jitsi_defined_tag_key = 'jitsi'

    conditions_list=['lifecycleState = \'AVAILABLE\'']

    conditions_list.append('(definedTags.key = \'Type\' && definedTags.value = \'%s\')'%type)

    if version and version != 'latest':
        conditions_list.append('(definedTags.key = \'Version\' && definedTags.value = \'%s\')'%version)

    image_conditions_str = ' && '.join(conditions_list)
    # results should be reverse order by create time as per
    # https://docs.oracle.com/en-us/iaas/Content/Search/Concepts/querysyntax.htm
    image_query_str='query image resources where (%s)'%image_conditions_str

    for region in regions:
        search = oci.resource_search.ResourceSearchClient(config)
        search.base_client.set_region(region)

        # print('searching %s : %s'%(region,image_query_str))
        image_resp = oci_search_resources(search, image_query_str)
        if image_resp and image_resp.data and len(image_resp.data.items) > 0:
            if version == 'latest':
                # latest so use only the first response, responses should already be reverse sorted by time
                image_data = [image_resp.data.items[0]]
            else:
                image_data = image_resp.data.items
            for i in image_data:
                # pprint.pprint(i)
                tags = {}
                tags.update(i.freeform_tags)
                if i.defined_tags:
                    for k in i.defined_tags:
                        tags.update(i.defined_tags[k])
                    if jitsi_defined_tag_key in i.defined_tags:
                        tags.update(i.defined_tags[jitsi_defined_tag_key])

                if 'TS' in tags:
                    ts = tags['TS']
                else:
                    utc_time = datetime.datetime.strptime('%s'%i.time_created, "%Y-%m-%d %H:%M:%S.%f+00:00")
                    ts = (utc_time - datetime.datetime(1970, 1, 1)).total_seconds()

                if 'Version' in tags:
                    version = tags['Version']
                else:
                    version = ts

                if 'build_id' in tags:
                    build_id = tags['build_id']
                else:
                    build_id = ''

                if 'environment_type' in tags:
                    image_environment_type = tags['environment_type']
                else:
                    image_environment_type = 'dev'

                if 'production-image' in tags:
                    image_production = True
                else:
                    image_production = False

                image = {
                    'image_ts':i.time_created,
                    'image_epoch_ts':ts,
                    'image_name':i.display_name,
                    'image_type':tags['Type'],
                    'image_version':version,
                    'image_id': i.identifier,
                    'image_build': build_id,
                    'image_environment_type':image_environment_type,
                    'image_status':i.lifecycle_state.upper(),
                    'image_region': region,
                    'image_production': image_production,
                    'tags':convert_tag_dict_to_aws_style(tags),
                    'freeform_tags': i.freeform_tags,
                    'defined_tags': i.defined_tags,
                    'image_compartment_id': compartment,
                    'provider':'oracle',
                }

                image_list.append(image)

    return image_list

def get_oracle_instance_list_by_search(role_name, environment_name, shard_name=False, regions=False,release_number=False,config=False,compartment=False,grid=False,grid_role=False):
    if not config:
        config = oci.config.from_file()
    if not compartment:
        compartment = get_oracle_compartment_by_environment(environment_name)

    if not regions:
        regions = oracle_regions()

    vnic = oci.core.VirtualNetworkClient(config)

    instance_list = []

    for region in regions:
        vnic.base_client.set_region(region)
        search = oci.resource_search.ResourceSearchClient(config)
        search.base_client.set_region(region)

        conditions_list=[]

        if role_name:
            role_conditions=['((definedTags.key = \'shard-role\' && definedTags.value = \'%s\') || (definedTags.key = \'role\' && definedTags.value = \'%s\'))'%(r,r) for r in role_name ]
            role_str = ' || '.join(role_conditions)
            conditions_list.append('(%s)'%role_str)

        if environment_name:
            conditions_list.append('(definedTags.key = \'environment\' && definedTags.value = \'%s\')'%environment_name)
        if shard_name:
            conditions_list.append('(definedTags.key = \'shard\' && definedTags.value = \'%s\')'%shard_name)
        if release_number:
            conditions_list.append('(definedTags.key = \'release_number\' && definedTags.value = \'%s\')'%release_number)
        if grid:
            conditions_list.append('(definedTags.key = \'grid\' && definedTags.value = \'%s\')'%grid)
        if grid_role:
            conditions_list.append('(definedTags.key = \'grid-role\' && definedTags.value = \'%s\')'%grid_role)

        vnic_conditions_str = ' && '.join(conditions_list)
        # only want the primary vnic
        vnic_conditions_str += " && (isPrimary = 'true')"

        instance_conditions_str = ' && '.join(conditions_list)
        # running instances only please
        instance_conditions_str += " && (lifecycleState = 'RUNNING')"

        instance_query_str='query instance resources where (%s)'%instance_conditions_str
#         vnic_query_str='query vnic resources where (%s)'%vnic_conditions_str

#         vnic_resp = oci_search_resources(search, vnic_query_str)
#         vnics_by_label={}
#         for v in vnic_resp.data.items:
#             vnic_details = get_vnic_details(vnic, v.identifier)
#             if vnic_details:
# #                pprint.pprint(vnic_details)
#                 vnics_by_label[vnic_details.display_name] = vnic_details

#        print('Query string: %s'%instance_query_str)
        instance_resp = oci_search_resources(search, instance_query_str)

        for i in instance_resp.data.items:
            instance_list.append(oracle_instance_from_oci_search(i,region,environment_name,compartment))


#            instance_list.append(instance);

#    pprint.pprint(instance_list)
    return instance_list

def oracle_instance_from_oci_sdk(i,region,environment_name,compartment):
    defined_tag_key = '%s-%s'%(ORACLE_TENANT,environment_name)
    jitsi_defined_tag_key = 'jitsi'

    tags = {}
    tags.update(i.freeform_tags)
    if i.defined_tags:
        if defined_tag_key in i.defined_tags:
            tags.update(i.defined_tags[defined_tag_key])
        if jitsi_defined_tag_key in i.defined_tags:
            tags.update(i.defined_tags[jitsi_defined_tag_key])
    private_ip=None
    public_ip=None
    if tags:
        if 'private_ip' in tags:
            private_ip = tags['private_ip']
        if 'public_ip' in tags:
            public_ip = tags['public_ip']

    instance = {
        'name':i.display_name,
        'id': i.id,
        'region': region,
        'tags':convert_tag_dict_to_aws_style(tags),
        'freeform_tags': i.freeform_tags,
        'defined_tags': i.defined_tags,
        'compartment_id': compartment.id,
        'launch_time':i.time_created,
        'cloud_name':'%s-%s'%(environment_name,region),
        'provider':'oracle',
        'private_ip_address': private_ip,
        'public_ip_address': public_ip
    }

    return OracleInstance(**instance)

def oracle_instance_from_oci_search(i,region,environment_name,compartment):
    defined_tag_key = '%s-%s'%(ORACLE_TENANT,environment_name)
    jitsi_defined_tag_key = 'jitsi'

#            pprint.pprint(i)
    tags = {}
    tags.update(i.freeform_tags)
    if i.defined_tags:
        if defined_tag_key in i.defined_tags:
            tags.update(i.defined_tags[defined_tag_key])
        if jitsi_defined_tag_key in i.defined_tags:
            tags.update(i.defined_tags[jitsi_defined_tag_key])
    private_ip=None
    public_ip=None
    if tags:
        if 'private_ip' in tags:
            private_ip = tags['private_ip']
        if 'public_ip' in tags:
            public_ip = tags['public_ip']

    instance = {
        'name':i.display_name,
        'id': i.identifier,
        'region': region,
        'tags':convert_tag_dict_to_aws_style(tags),
        'freeform_tags': i.freeform_tags,
        'defined_tags': i.defined_tags,
        'compartment_id': compartment.id,
        'launch_time':i.time_created,
        'cloud_name':'%s-%s'%(environment_name,region),
        'provider':'oracle',
        'private_ip_address': private_ip,
        'public_ip_address': public_ip
    }

    return OracleInstance(**instance)

def fix_oci_ip_tags(environment_name, regions=False,config=False,compartment=False):
    if not config:
        config = oci.config.from_file()

    if not compartment:
        compartment = get_oracle_compartment_by_environment(environment_name)
    if regions:
        regions = convert_aws_regions_to_oracle(regions)
    else:
        regions = ORACLE_REGIONS 

    for region in regions:
        compute = oci.core.ComputeClient(config)
        vnic = oci.core.VirtualNetworkClient(config)
        compute.base_client.set_region(region)
        vnic.base_client.set_region(region)
        response = oci.pagination.list_call_get_all_results(compute.list_instances, compartment.id, lifecycle_state='RUNNING')
        for i in response.data:
            if not 'private_ip' in i.freeform_tags:
                print('candidate for ip tags %s: %s'%(i.id,i.display_name))
 
                # lookup NIC details for instance
                vna = list_vnic_attachments_for_instance(compute, i.id, compartment.id)
                pv = get_primary_vnic(vnic, vna.data)
                ip_tags = {'private_ip':pv.private_ip}
                if pv.public_ip:
                    ip_tags['public_ip'] = pv.public_ip

                print('applying new tags')
                pprint.pprint(ip_tags)

                update_instance_tags(i, new_freeform_tags=ip_tags)

def get_oracle_instance_list_by_role(role_name, environment_name, shard_name=False,regions=False,release_number=False,config=False,compartment=False):
    instance_list = []

    if not config:
        config = oci.config.from_file()

    if not compartment:
        compartment = get_oracle_compartment_by_environment(environment_name)

    instances = []
    if regions:
        regions = convert_aws_regions_to_oracle(regions)
    else:
        regions = ORACLE_REGIONS 

    for region in regions:
        compute = oci.core.ComputeClient(config)
        compute.base_client.set_region(region)
        response = oci.pagination.list_call_get_all_results(compute.list_instances, compartment.id, lifecycle_state='RUNNING')
    #    response = compute.list_instances(compartment.id)
        defined_tag_key = '%s-%s'%(ORACLE_TENANT,environment_name)
        jitsi_defined_tag_key = 'jitsi'
        for i in response.data:
#            pprint.pprint(i)
            tags = {}
            tags.update(i.freeform_tags)
            if i.defined_tags:
                if defined_tag_key in i.defined_tags:
                    tags.update(i.defined_tags[defined_tag_key])
                if jitsi_defined_tag_key in i.defined_tags:
                    tags.update(i.defined_tags[jitsi_defined_tag_key])

            instance = {'id': i.id, 'region': region, 'tags':convert_tag_dict_to_aws_style(tags), 'provider':'oracle'}
#            pprint.pprint(instance)
            if not role_name or (('shard-role' in tags and tags['shard-role'] in role_name) or ('role' in tags and tags['role'] in role_name)):
                if not shard_name or ('shard' in tags and tags['shard']==shard_name):
                    if not release_number or ('release_number' in tags and tags['release_number']==release_number):
                        instance_list.append(instance)

    return instance_list

def list_vnic_attachments(compute, instance):
    return list_vnic_attachments_for_instance(instance['compartment_id'], instance_id=instance['id'])

@retry(tries=3, delay=60, backoff=2, max_delay=300)
def delete_image(compute,image_id):
    delete_image_response = compute.delete_image(image_id)
    return delete_image_response

@retry(tries=5, delay=1, backoff=5, max_delay=30)
def list_vnic_attachments_for_instance(compute, id, compartment_id):
    print('listing vnics for %s %s'%(compartment_id, id))
    return compute.list_vnic_attachments(compartment_id, instance_id=id)

def get_primary_vnic(vnic, vnic_list):
    primary_vnic = None
    for vnic_attachment in vnic_list:
        print('vnics details for %s'%(vnic_attachment.vnic_id))
        vnic_details = get_vnic_details(vnic, vnic_attachment.vnic_id)
        if vnic_details and vnic_details.is_primary:
            primary_vnic = vnic_details
            break
    return primary_vnic

@retry(tries=5, delay=1, backoff=5, max_delay=30)
def get_vnic_details(vnic, vnic_id):
    response = vnic.get_vnic(vnic_id)
    if response.data:
        return response.data
    else:
        return None

@retry(tries=5, delay=1, backoff=5, max_delay=30)
def oci_search_resources(search, query_str):
    resp = search.search_resources(
        oci.resource_search.models.StructuredSearchDetails(
            type="Structured",
            query=query_str
        )
    )
    return resp

def get_oracle_image_by_id(id, region):
    config = oci.config.from_file()
    compute = oci.core.ComputeClient(config)
    compute.base_client.set_region(region)
    image_response = compute.get_image(id)
    if image_response.data:
        found_image = image_response.data
        found_image.region = region
        return found_image
    
    return None

def update_image_tags(image, new_freeform_tags={}, new_defined_tags={}):
    config = oci.config.from_file()
    compute = oci.core.ComputeClient(config)
    compute.base_client.set_region(image.region)
    update_details = {}
    if len(new_freeform_tags.keys()) > 0:
        freeform_tags = image.freeform_tags
        freeform_tags.update(new_freeform_tags)
        update_details['freeform_tags'] = freeform_tags

    if len(new_defined_tags.keys()):
        defined_tags = image.defined_tags
        for k in new_defined_tags.keys():
            if not k in defined_tags:
                defined_tags[k] = {}
            defined_tags[k].update(new_defined_tags[k])

        update_details['defined_tags'] = defined_tags
    # pprint.pprint(update_details)
    details = oci.core.models.UpdateImageDetails(**update_details)
    # print(details)
    resp = compute.update_image(image.id, details)
    # print(resp.data)
    return resp

def update_instance_tags(instance, new_freeform_tags={}, new_defined_tags={}):
    config = oci.config.from_file()
    compute = oci.core.ComputeClient(config)
    compute.base_client.set_region(instance.region)
    update_details = {}
    if len(new_freeform_tags.keys()) > 0:
        freeform_tags = instance.freeform_tags
        freeform_tags.update(new_freeform_tags)
        update_details['freeform_tags'] = freeform_tags

    if len(new_defined_tags.keys()):
        defined_tags = instance.defined_tags
        for k in new_defined_tags.keys():
            if not k in defined_tags:
                defined_tags[k] = {}
            defined_tags[k].update(new_defined_tags[k])

        update_details['defined_tags'] = defined_tags
    # pprint.pprint(update_details)
    details = oci.core.models.UpdateInstanceDetails(**update_details)
    # print(details)
    resp = compute.update_instance(instance.id, details)
    # print(resp.data)
    return resp

def get_oracle_instances_by_role(role_name, environment_name, shard_name=False,region=False,regions=False,shard_state=False,release_number=False,cloud_provider=False,grid=False,grid_role=False):
    config = oci.config.from_file()
    vnic = oci.core.VirtualNetworkClient(config)
    compute = oci.core.ComputeClient(config)
    compartment = get_oracle_compartment_by_environment(environment_name)

    return get_oracle_instance_list_by_search(role_name, environment_name=environment_name,shard_name=shard_name,regions=regions,release_number=release_number,config=config,compartment=compartment,grid=grid,grid_role=grid_role)

def get_instances_by_role(role_name, environment_name=False,shard_name=False,region=False,regions=False,shard_state=False,release_number=False,cloud_provider=False,grid=False,grid_role=False):
    if hcv_debug: print((inspect.currentframe().f_code.co_name))

    # when role_name is 'all', just don't filter on role
    if role_name == 'all':
        roles = False
    else:
        # force role into a list if not already a list
        if not isinstance(role_name,list):
            roles = [role_name]
        else:
            roles = list(set(role_name))

    filters = [
            {'Name': 'instance-state-name', 'Values': ['running']}
        ]

    if roles:
        filters.append({'Name': 'tag:' + SHARD_ROLE_TAG, 'Values': roles})

    if environment_name:
        filters.append({'Name':'tag:'+ENVIRONMENT_TAG, 'Values':[environment_name]})
    if shard_name:
        filters.append({'Name':'tag:'+SHARD_TAG, 'Values':[shard_name]})
    if shard_state:
        filters.append({'Name':'tag:'+SHARD_STATE_TAG, 'Values':[shard_state]})
    if release_number:
        filters.append({'Name':'tag:'+RELEASE_NUMBER_TAG, 'Values':[release_number]})
    if cloud_provider:
        filters.append({'Name':'tag:'+CLOUD_PROVIDER_TAG, 'Values':[cloud_provider]})
    if grid:
        filters.append({'Name':'tag:'+GRID_TAG, 'Values':[grid]})
    if grid_role:
        filters.append({'Name':'tag:'+GRID_ROLE_TAG, 'Values':[grid_role]})

    global AWS_REGIONS
    if not regions:
        if region:
            regions = [region]
        else:
            regions = AWS_REGIONS

    final_instances = []
    for region in regions:
        ec2 = init_ec2(region)
        vpcs = get_all_vpcs(region)
        instances = ec2.instances.filter(
            Filters=filters)
        for instance in instances:
            instance.region = region
            instance.provider = 'aws'
            instance_tags = dict([(x['Key'], x['Value']) for x in instance.tags or []])

            instance.cloud_name = instance_tags['cloud_name'] if 'cloud_name' in instance_tags else cloud_name_from_vpc_name(extract_tag(vpcs[instance.vpc_id]['Tags'],'Name'))
            final_instances.append(instance)

    return final_instances

def cloud_name_from_vpc_name(vpc_name):
    cloud_name = vpc_name.replace('-vpc','')
    cloud_name = cloud_name.replace('/VPC','')

    return cloud_name

def init_ec2(region='us-east-1'):
    if hcv_debug: print((inspect.currentframe().f_code.co_name))
    ec2 = boto3.resource('ec2', region_name=region)
    return ec2


def create_metric_item(metric, metric_value, stats_values=None, metric_time=None, metric_unit=None, environment=None, shard=None, instance=None):
    dimensions = []

    if not metric_time:
        metric_time = datetime.datetime.utcnow()

    if not metric_unit:
        metric_unit='None'

    if instance:
        dimensions.append({'Name':'InstanceId','Value':instance})

    else:
        if environment:
            dimensions.append({'Name':'Environment','Value':environment})

        if shard:
            dimensions.append({'Name':'Shard','Value':shard})

    metric_item = {
                'MetricName': metric,
                'Dimensions': dimensions,
                'Timestamp': metric_time,
                'Value': metric_value,
                'Unit': metric_unit
            }
                # example stats values and units
                # 'StatisticValues': {
                #     'SampleCount': 123.0,
                #     'Sum': 123.0,
                #     'Minimum': 123.0,
                #     'Maximum': 123.0
                # },
                # 'Unit': 'Seconds'|'Microseconds'|'Milliseconds'|'Bytes'|'Kilobytes'|'Megabytes'|'Gigabytes'|'Terabytes'|'Bits'|'Kilobits'|'Megabits'|'Gigabits'|'Terabits'|'Percent'|'Count'|'Bytes/Second'|'Kilobytes/Second'|'Megabytes/Second'|'Gigabytes/Second'|'Terabytes/Second'|'Bits/Second'|'Kilobits/Second'|'Megabits/Second'|'Gigabits/Second'|'Terabits/Second'|'Count/Second'|'None'
    if stats_values:
        metric_item['StatisticValues'] = stats_values

    return metric_item


def put_metrics(metric_data, namespace='Video', region=None):
    if not region:
        region=AWS_DEFAULT_REGION

    client = boto3.client('cloudwatch', region_name=region)

    response = client.put_metric_data(
        Namespace=namespace,
        MetricData=metric_data
    )

    return response



def put_metric(metric, metric_value, stats_values=None, metric_time=None, metric_unit=None, namespace='Video', environment=None, shard=None, instance=None, region=None):
    metric_data=[]
    metric_item=create_metric_item(metric=metric,metric_value=metric_value,stats_values=stats_values,metric_time=metric_time,metric_unit=metric_unit,environment=environment,shard=shard,instance=instance)
    metric_data.append(metric_item)
    return put_metrics(metric_data=metric_data, namespace=namespace,region=region)


def get_metric(metric='JVB_conferences', namespace='Video', environment=None, shard=None, instance=None, start=None, end=None, period=60, region=None):
    if not region:
        region=AWS_DEFAULT_REGION
    client = boto3.client('cloudwatch', region_name=region)

    dimensions = []

    if not start:
        start = datetime.datetime.utcnow()- datetime.timedelta(minutes=5)
    if not end:
        end = datetime.datetime.utcnow()

    if instance:
        dimensions.append({'Name':'InstanceId','Value':instance})

    else:
        if environment:
            dimensions.append({'Name':'Environment','Value':environment})

        if shard:
            dimensions.append({'Name':'Shard','Value':shard})

    if not len(dimensions) > 0:
        return False
    else:
        statistics=['Sum','Average','Maximum']
        return client.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric,
            Dimensions=dimensions,
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=statistics
        )


def create_ami_tag(ec2, image, image_type, image_version, image_ts=None):

    #default tags applied to all AMIs
    new_tags=[
            {
                'Key': 'Name',
                'Value': image.name
            },
            {
                'Key':'Type',
                'Value': image_type
            },
            {
                'Key':'Product',
                'Value': 'meetings'
            },
            {
                'Key':'Owner',
                'Value': 'Meetings'
            },
            {
                'Key':'Team',
                'Value': 'meet@8x8.com'
            }
    ]
    if image_version:
        new_tags.append(
            {
                'Key': 'Version',
                'Value': image_version
            }
        )
    if image_ts:
        new_tags.append(
            {
                'Key': 'TS',
                'Value': image_ts
            }
        )
    image.new_tags = new_tags
#    pprint.pprint(new_tags)
    return image.create_tags(
        Tags=new_tags
    )

def add_image_tag(ec2, name_filter):
    out_images = []
    if name_filter == 'all':
        ami_images = ec2.images.filter(Owners=['self'], Filters=[{'Name': 'name', 'Values': ['Build*','Jitsi*']}])
    else:
        ami_images = ec2.images.filter(Owners=['self'],Filters=[{'Name':'name','Values':['Build'+name_filter+'*','Jitsi'+name_filter+'*']}])

    for image in ami_images:
        #define new_tags on every image we encounter
        image.new_tags = None
        image_type = None
        image_name_pieces = image.name.split('-')
        if len(image_name_pieces) < 2:
            #not an expected name, so something went wrong
            print(('Unexpected image name found: %s'%image.name))
        else:
            image_base = image_name_pieces[0]
            image_ts = image_name_pieces[-1]
            image_version = version_from_image_name(image.name, image_base)
            if image_base.startswith('Build'):
                image_type = re.split('Build',image_base)[1]
            elif image_base.startswith('Jitsi'):
                image_type = re.split('Jitsi',image_base)[1]
                image_version = None


        if image_type:
            #checks for presence of tags before creating new ones
            if image.tags is None:
                #definitely create new tags if there aren't any defined
                pass
            else:
                image_tags = dict([(x['Key'], x['Value']) for x in image.tags or []])
                if not image_version:
                    if 'Type' in image_tags and 'Name' in image_tags :
                        #no need to write tags, we've got the tags we could define, so continue to next image
#                        print('Tags already set for image %s'%image.id)
                        continue
                else:
                    if 'Type' in image_tags and 'Name' in image_tags and 'Version' in image_tags:
                        #all tags provided, so don't set any
#                        print('Tags already set for image %s'%image.id)
                        continue
            #none of the checks skipped the creation of the tags, so create them
#            print('creating new tags for %s image %s'%(image_type,image.id))
            create_ami_tag(ec2, image, image_type, image_version=image_version, image_ts=image_ts)
            out_images.append(image_data_from_image_obj(image))

    out_images=sorted(out_images,key=lambda timg: timg['image_ts'], reverse=True)
    return out_images


def delete_route53_alarm(cf_region, stack_name, cw_region='us-east-1'):
    """This function removes CloudWatch alarm for Route53 HealthCheck in the us-east-1 region.

    :param region: Region that contains CloudFormation stack
    :param stack_name: CloudFormation stack name
    """

    client_cw = boto3.client('cloudwatch', region_name=cw_region)
    client_cf = boto3.client('cloudformation', region_name=cf_region)
    cw_alarm_id = None

    response_cf = client_cf.describe_stack_resources(
        StackName=stack_name,
    )

    for r in response_cf['StackResources']:
        if r['LogicalResourceId'] == 'Route53XMPPHealthCheckFailedAlarm':
            cw_alarm_id = r.get('PhysicalResourceId', None)

    if cw_alarm_id:
        response = client_cw.delete_alarms(
            AlarmNames=[cw_alarm_id]
        )

def pull_network_stack_outputs(region, regionalias, stackprefix):
    output = {}
    if not regionalias:
        regionalias = region

    stack_name = regionalias + "-" + stackprefix + "-network"

    client = boto3.client( 'cloudformation', region_name=region )
    response = client.describe_stacks(
        StackName=stack_name
    )

    for stack in response["Stacks"]:
            outputs =  dict([(x['OutputKey'], x['OutputValue']) for x in stack['Outputs']])
            output['EC2_VPC_ID'] = outputs.get('VPC')
            output['EC2_VPC_SUBNET'] = outputs.get("PublicSubnetA")
            output['DEFAULT_PUBLIC_SUBNET_ID_a'] = outputs.get("PublicSubnetA")
            output['DEFAULT_PUBLIC_SUBNET_ID_b'] = outputs.get("PublicSubnetB")
            output['EC2_VPC_ID'] = outputs.get('VPC')
            output['SSH_SECURITY_GROUP'] = outputs.get('SSHSecurityGroup')
            output['JVB_SECURITY_GROUP'] = outputs.get('JVBSecurityGroup')
            output['CORE_SECURITY_GROUP'] = outputs.get('SignalSecurityGroup')

            output['JVB_SUBNET_ID_a'] = outputs.get("JVBSubnetsA")
            output['JVB_SUBNET_ID_b'] = outputs.get("JVBSubnetsB")

    stack_name = regionalias + "-" + stackprefix + "-NAT-network"
    try:
        client = boto3.client( 'cloudformation', region_name=region )
        response = client.describe_stacks(
            StackName=stack_name
        )

        for stack in response["Stacks"]:
                outputs =  dict([(x['OutputKey'], x['OutputValue']) for x in stack['Outputs']])
                output['NAT_SUBNET_IDS'] = outputs.get('NATSubnetA') + ','+outputs.get('NATSubnetB')
                output['SIP_JIBRI_SUBNET_IDS'] = output['NAT_SUBNET_IDS']
                output['JIGASI_SUBNET_IDS'] = output['NAT_SUBNET_IDS']
    except ClientError as e:
        pass
        # print((e.response['Error']['Message']))

    stack_name = regionalias + "-" + stackprefix + "-jigasi-network"
    try:
        client = boto3.client( 'cloudformation', region_name=region )
        response = client.describe_stacks(
            StackName=stack_name
        )

        for stack in response["Stacks"]:
                outputs =  dict([(x['OutputKey'], x['OutputValue']) for x in stack['Outputs']])
                output['JIGASI_SUBNET_IDS'] = outputs.get('JigasiSubnetA') + ','+ outputs.get('JigasiSubnetB')

    except ClientError as e:
        pass
#         print((e.response['Error']['Message']))

    stack_name = regionalias + "-" + stackprefix + "-sip-jibri-network"
    try:
        client = boto3.client( 'cloudformation', region_name=region )
        response = client.describe_stacks(
            StackName=stack_name
        )

        for stack in response["Stacks"]:
                outputs =  dict([(x['OutputKey'], x['OutputValue']) for x in stack['Outputs']])
                output['SIP_JIBRI_SUBNET_IDS'] = outputs.get('SipJibriSubnetsIds')

    except ClientError as e:
        pass
#        print((e.response['Error']['Message']))


    return output

# def pull_bash_network_stack(az_letter):
#     output = {}
#     output['EC2_VPC_ID'] = os.environ['EC2_VPC_ID']
#     output['EC2_VPC_SUBNET'] = outputs.get("PublicSubnetA")
#     output['DEFAULT_PUBLIC_SUBNET_ID_a'] = os.environ['DEFAULT_PUBLIC_SUBNET_ID_a']
#     output['DEFAULT_PUBLIC_SUBNET_ID_b'] = os.environ['DEFAULT_PUBLIC_SUBNET_ID_b']
#     output['EC2_VPC_ID'] = outputs.get('VPC')
#     output['SSH_SECURITY_GROUP'] = outputs.get('SSHSecurityGroup')
#     output['JVB_SECURITY_GROUP'] = outputs.get('JVBSecurityGroup')
#     output['CORE_SECURITY_GROUP'] = os.environ['SIGNAL_SECURITY_GROUP']

#     output['JVB_SUBNET_ID_a'] = os.environ['DEFAULT_PUBLIC_SUBNET_ID_a']

#     if az_letter == "a":
#         subnetId = public_subnetA
#         jvb_zone_id = os.environ['DEFAULT_DC_SUBNET_IDS_a']
#         output['JVB_SUBNET_ID_b'] = os.environ['DEFAULT_PUBLIC_SUBNET_ID_b']
#     elif az_letter in ["b","c"]:
#         subnetId = public_subnetB
#         jvb_zone_id= os.environ['DEFAULT_DC_SUBNET_IDS_b']
#         output['JVB_SUBNET_ID_b'] = os.environ['DEFAULT_PUBLIC_SUBNET_ID_b']


#     vpc_id =
#     signal_security_group = 
#     public_subnetA = 
#     public_subnetB = 
#     ssh_security_group = os.environ['SSH_SECURITY_GROUP']
#     jvb_security_group = os.environ['JVB_SECURITY_GROUP']


#     if az_letter == "a":
#         subnetId = public_subnetA
#         jvb_zone_id = os.environ['DEFAULT_DC_SUBNET_IDS_a']
#     elif az_letter in ["b","c"]:
#         subnetId = public_subnetB
#         jvb_zone_id= os.environ['DEFAULT_DC_SUBNET_IDS_b']