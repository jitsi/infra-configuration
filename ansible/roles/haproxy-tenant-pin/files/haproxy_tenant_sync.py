# standard libs
import base64
import time
from datetime import datetime, timedelta

# pip installs
import click
from datadog import statsd
from haproxyadmin import haproxy
import requests

def fetch_map_from_consul(ctx, subpath):
    '''
    get a list of all tenant releases from local datacenter
    Parameters:
        ctx (dict): the context
        subpath (string): the subpath where all items reside
    Returns:
        result (list): a linefeed delimited list of items, formatted for use in a haproxy map file
    '''
    pin_url = f"{ctx.obj['CONSUL_URL']}/v1/kv/{subpath}?recurse=true"
    response = requests.get(pin_url)
    if response.text == '':
        if ctx.obj['DEBUG']:
            click.echo(f"## empty response from {pin_url}")
        return []
    try:
        response_json = response.json()
    except requests.exceptions.JSONDecodeError:
        if ctx.obj['DEBUG']:
            click.echo(f"## invalid JSON from {pin_url}: {response.text}")
        return None
    result = []
    for r in response_json:
        rkey = r['Key'].split('/')[-1]
        result.append(f"{rkey} {base64.b64decode(r['Value']).decode('ascii')}")
    return result 

def fetch_all_tenant_releases(ctx):
    '''
    get a list of all tenant releases from local datacenter
    Parameters:
        ctx (dict): the context
    Returns:
        result (list): a linefeed delimited list of tenant to release pins, formatted for use in a haproxy map file
    '''
    return fetch_map_from_consul(ctx, f"releases/{ctx.obj['ENVIRONMENT']}/tenant")

def fetch_all_banned_rooms(ctx):
    '''
    get a list of all banned room names from local datacenter
    Parameters:
        ctx (dict): the context
    Returns:
        result (list): a linefeed delimited list of banned room names, formatted for use in a haproxy map file
    '''
    return fetch_map_from_consul(ctx, f"bans/{ctx.obj['ENVIRONMENT']}/room")

def fetch_all_banned_tenants(ctx):
    '''
    get a list of all banned tenant names from local datacenter
    Parameters:
        ctx (dict): the context
    Returns:
        result (list): a linefeed delimited list of banned room names, formatted for use in a haproxy map file
    '''
    return fetch_map_from_consul(ctx, f"bans/{ctx.obj['ENVIRONMENT']}/tenant")

def emit_metrics(ctx, report):
    ''' emit metrics to statsd '''
    if not ctx.obj['STATSD_ENABLED']:
        return

    if ctx.obj['DRY_RUN']:
        click.echo('# DRY RUN MODE -- did not emit metrics to statsd')
        return

    prefix = 'jitsi'
    tags = []

    statsd.increment(f"{prefix}_tenant_pin_runs", tags=tags)
    if ctx.obj['DEBUG']:
        click.echo("## STATSD: incremented tenant_pin_runs")

    if len(report['errors']) > 0:
        statsd.gauge(f"{prefix}_tenant_pin_errors", len(report['errors']), tags=tags)
        if ctx.obj['DEBUG']:
            click.echo(f"## STATSD: tenant_pin_errors: {len(report['errors'])}")

    if not report['failed_early']:
        pins_configured = len(str.splitlines(report['map_file_contents']))
        pins_invalid = len(report['invalid']) + len(report['persisted'])
        statsd.gauge(f"{prefix}_tenant_pin_configured", pins_configured, tags)
        statsd.gauge(f"{prefix}_tenant_pin_invalid", pins_invalid, tags)
        if ctx.obj['DEBUG']:
            click.echo(f"## STATSD: tenant_pin_configured: {pins_configured}, tenant_pin_invalid: {pins_invalid}")
    else:
        if ctx.obj['DEBUG']:
            click.echo('## STATSD did not emit pin stats due to a failure to fetch maps from consul or the haproxy')


def output_report(ctx, report):
    ''' return metrics about the run '''
    if ctx.obj['DRY_RUN']:
        click.echo('# DRY RUN MODE -- no actions were performed')

    if len(report['unchanged']) > 0:
        if ctx.obj['DEBUG']:
            click.echo(f"## left {len(report['unchanged'])} entries unchanged in the live map")
            for unchanged in report['unchanged']:
                click.echo(unchanged)
    if len(report['add']) > 0:
        click.echo(f"## added {len(report['add'])} entries to the live map")
        if ctx.obj['DEBUG']:
            for added in report['add']:
                click.echo(added)
    if len(report['update']) > 0:
        click.echo(f"## updated {len(report['update'])} entries in the live map")
        if ctx.obj['DEBUG']:
            for updated in report['update']:
                click.echo(updated)
    if len(report['delete']) > 0:
        click.echo(f"## deleted {len(report['delete'])} entries in the live map")
        if ctx.obj['DEBUG']:
            for deleted in report['delete']:
                click.echo(deleted)
    if len(report['invalid']) > 0:
        click.echo(f"## WARNING: ignored {len(report['invalid'])} invalid entries in consul:")
        for invalid in report['invalid']:
            click.echo(f"  {invalid}")
    if len(report['persisted']) > 0:
        click.echo(f"## WARNING: persisted {len(report['persisted'])} entries in the live map with invalid consul entries:")
        for persisted in report['persisted']:
            click.echo(persisted)
    if len(report['add']) > 0 or len(report['update']) > 0 or len(report['delete']) > 0:
        if ctx.obj['DEBUG']:
            click.echo(f"## replaced tenant map file {ctx.obj['TENANT_MAP']} with:\n{report['map_file_contents']}")
        else:
            click.echo(f"## updated tenant map file {ctx.obj['TENANT_MAP']}")
    if len(report['unchanged_banned_rooms']) > 0:
        if ctx.obj['DEBUG']:
            click.echo(f"## left {len(report['unchanged_banned_rooms'])} banned rooms unchanged in the live map")
            for unchanged in report['unchanged_banned_rooms']:
                click.echo(unchanged)
    if len(report['add_banned_rooms']) > 0:
        click.echo(f"## added {len(report['add_banned_rooms'])} banned rooms to the live map")
        if ctx.obj['DEBUG']:
            for added in report['add_banned_rooms']:
                click.echo(added)
    if len(report['update_banned_rooms']) > 0:
        click.echo(f"## updated {len(report['update_banned_rooms'])} banned rooms in the live map")
        if ctx.obj['DEBUG']:
            for updated in report['update_banned_rooms']:
                click.echo(updated)
    if len(report['delete_banned_rooms']) > 0:
        click.echo(f"## deleted {len(report['delete_banned_rooms'])} banned rooms in the live map")
        if ctx.obj['DEBUG']:
            for deleted in report['delete_banned_rooms']:
                click.echo(deleted)
    if len(report['add_banned_rooms']) > 0 or len(report['update_banned_rooms']) > 0 or len(report['delete_banned_rooms']) > 0:
        if ctx.obj['DEBUG']:
            click.echo(f"## replaced banned room map file {ctx.obj['BANNED_ROOM_MAP']} with:\n{report['banned_rooms_map_file_contents']}")
        else:
            click.echo(f"## updated banned room map file {ctx.obj['BANNED_ROOM_MAP']}")
    if len(report['unchanged_banned_tenants']) > 0:
        if ctx.obj['DEBUG']:
            click.echo(f"## left {len(report['unchanged_banned_tenants'])} banned tenants unchanged in the live map")
            for unchanged in report['unchanged_banned_tenants']:
                click.echo(unchanged)
    if len(report['add_banned_tenants']) > 0:
        click.echo(f"## added {len(report['add_banned_tenants'])} banned tenants to the live map")
        if ctx.obj['DEBUG']:
            for added in report['add_banned_tenants']:
                click.echo(added)
    if len(report['update_banned_tenants']) > 0:
        click.echo(f"## updated {len(report['update_banned_tenants'])} banned tenants in the live map")
        if ctx.obj['DEBUG']:
            for updated in report['update_banned_tenants']:
                click.echo(updated)
    if len(report['delete_banned_tenants']) > 0:
        click.echo(f"## deleted {len(report['delete_banned_tenants'])} banned tenants in the live map")
        if ctx.obj['DEBUG']:
            for deleted in report['delete_banned_tenants']:
                click.echo(deleted)
    if len(report['add_banned_tenants']) > 0 or len(report['update_banned_tenants']) > 0 or len(report['delete_banned_tenants']) > 0:
        if ctx.obj['DEBUG']:
            click.echo(f"## replaced banned tenant map file {ctx.obj['BANNED_TENANT_MAP']} with:\n{report['banned_tenants_map_file_contents']}")
        else:
            click.echo(f"## updated banned tenant map file {ctx.obj['BANNED_TENANT_MAP']}")
    else:
        if ctx.obj['DEBUG']:
            click.echo("## took no action due to no changes found")

def dict_from_consul(clist):
    if not isinstance(clist, list):
        click.echo("## WARNING: failed to fetch from consul; aborting")
        raise Exception(code='consul_fetch')
    return { item.split()[0]: item.split()[1] for item in clist }

def dict_from_haproxy(ctx, map_key):
    try:
        haproxy_map = ctx.obj['HAPROXY_SOCKET'].show_map(ctx.obj[map_key])
    except OSError as exception:
        click.echo(f"## WARNING: failed get live haproxy map {map_key}; aborting sync attempt\n{exception}")
        raise Exception(code='haproxy_socket')
    return  { item.split()[1]: item.split()[2] for item in haproxy_map }

def sync_haproxy(ctx):
    ''' perform the sync itself '''
    report = {
        'add': [],        # added to haproxy because new in consul
        'update': [],     # updated on haproxy because changed in consul
        'delete': [],     # deleted from haproxy because it wasn't in consul
        'invalid': [],    # invalid pin in consul and ignored
        'persisted': [],  # persisted valid pin in haproxy despite invalid consul pin
        'unchanged': [],  # same in haproxy and consul; also includes 'persisted' pins
        'add_banned_rooms': [],        # added ban to haproxy because new in consul
        'update_banned_rooms': [],     # updated ban on haproxy because changed in consul
        'delete_banned_rooms': [],     # deleted ban from haproxy because it wasn't in consul
        'unchanged_banned_rooms': [],  # same ban in haproxy and consul
        'add_banned_tenants': [],        # added ban to haproxy because new in consul
        'update_banned_tenants': [],     # updated ban on haproxy because changed in consul
        'delete_banned_tenants': [],     # deleted ban from haproxy because it wasn't in consul
        'unchanged_banned_tenants': [],  # same ban in haproxy and consul
        'map_file_contents': '',
        'banned_rooms_map_file_contents': '',
        'banned_tenants_map_file_contents': '',
        'errors': [],
        'failed_early': False,
    }

    consul_tenant_releases = fetch_all_tenant_releases(ctx)
    consul_banned_rooms = fetch_all_banned_rooms(ctx)
    consul_banned_tenants = fetch_all_banned_tenants(ctx)
    try:
        consul_tenant_dict = dict_from_consul(consul_tenant_releases)
        consul_banned_rooms_dict = dict_from_consul(consul_banned_rooms)
        consul_banned_tenants_dict = dict_from_consul(consul_banned_tenants)

        haproxy_tenant_dict = dict_from_haproxy(ctx, 'TENANT_MAP')
        haproxy_banned_rooms_dict = dict_from_haproxy(ctx, 'BANNED_ROOM_MAP')
        haproxy_banned_tenants_dict = dict_from_haproxy(ctx, 'BANNED_TENANT_MAP')

    except Exception as inst:
        report['errors'].append(inst.args['code'])
        report['failed_early'] = True
        return report

    report.extend(write_map_and_update_haproxy(ctx, 'TENANT_MAP', '', consul_tenant_dict, haproxy_tenant_dict, True))
    report.update(write_map_and_update_haproxy(ctx, 'BANNED_ROOM_MAP', 'banned_rooms', consul_banned_rooms_dict, haproxy_banned_rooms_dict))
    report.update(write_map_and_update_haproxy(ctx, 'BANNED_TENANT_MAP', 'banned_tenants', consul_banned_tenants_dict, haproxy_banned_tenants_dict))

    return report

def write_map_and_update_haproxy(ctx, map_type, ctype, consul_dict, haproxy_dict, check_backends=False):
    invalid_key = f"invalid{'_'+ctype if ctype else ''}"
    persisted_key = f"persisted{'_'+ctype if ctype else ''}"
    unchanged_key = f"unchanged{'_'+ctype if ctype else ''}"
    update_key = f"update{'_'+ctype if ctype else ''}"
    errors_key = f"errors{'_'+ctype if ctype else ''}"
    delete_key = f"delete{'_'+ctype if ctype else ''}"
    add_key = f"add{'_'+ctype if ctype else ''}"
    map_file_contents_key = f"{ctype+'_' if ctype else ''}map_file_contents"
    ireport={
        invalid_key: [], # invalid pin in consul and ignored
        persisted_key: [], # persisted valid pin in haproxy despite invalid consul pin
        unchanged_key: [], # same in haproxy and consul; also includes 'persisted' pins
        update_key: [], # updated on haproxy because changed in consul
        delete_key: [], # deleted from haproxy because it wasn't in consul
        add_key: [],  # added to haproxy because new in consul
        map_file_contents_key: '',
        errors_key: []
    }
    # check pins from consul against live backends for invalid entries
    for ckey in consul_dict.keys():
        if check_backends:
            # get pins from consul, live map from haproxy, and live backends from haproxy
            haproxy_backends = [backend.name for backend in ctx.obj['HAPROXY_SOCKET'].backends()]

            if consul_dict[ckey] not in haproxy_backends:
                ## if there is an existing valid pin, persist it
                if ckey in haproxy_dict.keys() and haproxy_dict[ckey] in haproxy_backends:
                    consul_dict[ckey] = haproxy_dict[ckey]
                    ireport[persisted_key].append(f"{ckey} {consul_dict[ckey]}")
                else:
                    ireport[invalid_key].append(f"{ckey} {consul_dict[ckey]}")

    # build the map file
    for invalid_item in ireport[invalid_key]:
        consul_dict.pop(invalid_item.split()[0])
    ireport[map_file_contents_key] = "\n".join([f"{ckey} {consul_dict[ckey]}" for ckey in consul_dict.keys()])

    # check live pins in haproxy and update/delete if needed, pops these out of the dict
    for ckey in haproxy_dict.keys():
        if ckey in consul_dict.keys():
            if haproxy_dict[ckey] == consul_dict[ckey]:
                ireport[unchanged_key].append(f"{ckey} {haproxy_dict[ckey]}")
                consul_dict.pop(ckey)
            else:
                if not ctx.obj['DRY_RUN']:
                    success = ctx.obj['HAPROXY_SOCKET'].set_map(ctx.obj[map_type], ckey, consul_dict[ckey])
                    if not success:
                        click.echo("## failed to set_map")
                        ireport[errors_key].append('haproxy_socket')
                ireport[update_key].append(f"{ckey} {consul_dict[ckey]}")
                consul_dict.pop(ckey)
        else:
            # delete from the live haproxy map because there isn't a pin in consul
            if not ctx.obj['DRY_RUN']:
                success = ctx.obj['HAPROXY_SOCKET'].del_map(ctx.obj[map_type], ckey)
                if not success:
                    click.echo("## failed to set_map")
                    ireport[errors_key].append('haproxy_socket')
            ireport[delete_key].append(f"{ckey} {haproxy_dict[ckey]}")
        # remaining entries in consul_dict need to be added to the live haproxy map
        for ckey in consul_dict.keys():
            if not ctx.obj['DRY_RUN']:
                success = ctx.obj['HAPROXY_SOCKET'].add_map(ctx.obj[map_type], ckey, consul_dict[ckey])
                if not success:
                    click.echo("## failed to set_map")
                    ireport[errors_key].append('haproxy_socket')
            ireport[add_key].append(f"{ckey} {consul_dict[ckey]}")

        # update the map file, only if there have been changes
        if not ctx.obj['DRY_RUN']:
            if len(ireport[add_key]) > 0 or len(ireport[update_key]) > 0 or len(ireport[delete_key]) > 0:
                try:
                    with open(ctx.obj[map_type], 'w', encoding="UTF-8") as ckey_map_file:
                        ckey_map_file.write(ireport[map_file_contents_key])
                except OSError:
                    ireport[errors_key].append('map_file_write')

    return ireport

def daemon_loop(ctx):
    ''' main loop to run as a daemon '''
    ctx.obj['CHECK_RUNS'] = 0
    ctx.obj['CHECK_TIME'] = datetime.now()
    while True:
        ctx.obj['CHECK_RUNS'] += 1
        if ctx.obj['DEBUG']:
            click.echo("# syncing haproxy tenants with consul...")
        report = sync_haproxy(ctx)
        output_report(ctx, report)
        emit_metrics(ctx, report)
        if datetime.now() > ctx.obj['CHECK_TIME'] + timedelta(hours=1):
            click.echo(f"# ran {ctx.obj['CHECK_RUNS']} times in the last hour; expected {3600 / ctx.obj['TICK_DURATION']} runs")
            ctx.obj['CHECK_RUNS'] = 0
            ctx.obj['CHECK_TIME'] = datetime.now()
        time.sleep(ctx.obj['TICK_DURATION'])


@click.command()
@click.option('--tenant-map', 'tenant_map', envvar=['TENANT_MAP_PATH'], default='/etc/haproxy/maps/tenant.map', show_default=True, help='path to tenant map file')
@click.option('--ban-room-map', 'banned_room_map', envvar=['BANNED_ROOM_MAP_PATH'], default='/etc/haproxy/maps/banned_rooms.map', show_default=True, help='path to banned room map file')
@click.option('--ban-tenant-map', 'banned_tenant_map', envvar=['BANNED_TENANT_MAP_PATH'], default='/etc/haproxy/maps/banned_tenants.map', show_default=True, help='path to banned tenant map file')
@click.option('--consul-url', '--url', 'consul_url', envvar=['CONSUL_URL'], default='http://localhost:8500', show_default=True, help='url of consul server')
@click.option('--environment', required=True, envvar=['ENVIRONMENT', 'HCV_ENVIRONMENT'], help='jitsi environment')
@click.option('--daemon', '-d', envvar=['DAEMON_MODE'], is_flag=True, help='run as a daemon')
@click.option('--tick_duration', envvar=['DAEMON_TICK_DURATION'], default=5, help='duration of ticker for daemon mode in seconds')
@click.option('--statsd', 'statsd_enabled', envvar=['STATSD_ENABLED'], is_flag=True, default=False, show_default=True, help='emit results to statsd')
@click.option('--debug', '-v', is_flag=True, envvar=['DEBUG'], help='verbose debug messages')
@click.option('--dry-run', 'dry_run', is_flag=True, help='leave map unchanged')
@click.pass_context
def sync(ctx, tenant_map, banned_room_map, banned_tenant_map, consul_url, environment, daemon, tick_duration, statsd_enabled, debug, dry_run):
    ''' main click command '''
    ctx.ensure_object(dict)
    ctx.obj['CONSUL_URL'] = consul_url
    ctx.obj['ENVIRONMENT'] = environment
    ctx.obj['TENANT_MAP'] = tenant_map
    ctx.obj['BANNED_ROOM_MAP'] = banned_room_map
    ctx.obj['BANNED_TENANT_MAP'] = banned_tenant_map
    ctx.obj['TICK_DURATION'] = tick_duration
    ctx.obj['DRY_RUN'] = dry_run
    ctx.obj['STATSD_ENABLED'] = statsd_enabled
    ctx.obj['DEBUG'] = debug
    
    try:
        ctx.obj['HAPROXY_SOCKET'] = haproxy.HAProxy(socket_dir='/var/run/haproxy')
    except OSError as exception:
        exit(f"# haproxy_tenant_sync failed to set up haproxy socket, error: {exception}.")

    click.echo(f"# running haproxy-tenant-sync with consul_url: {consul_url}, environment: {environment}")
    if daemon:
        click.echo(f"# starting daemon mode with a {ctx.obj['TICK_DURATION']} second ticker")
        daemon_loop(ctx)
    else:
        report = sync_haproxy(ctx)
        output_report(ctx, report)
        emit_metrics(ctx, report)

if __name__ == '__main__':
    sync()
