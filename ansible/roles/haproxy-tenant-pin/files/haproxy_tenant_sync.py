# standard libs
import base64
import time
from datetime import datetime, timedelta

# pip installs
import click
from datadog import statsd
from haproxyadmin import haproxy
import requests

def fetch_all_tenant_releases(ctx):
    '''
    get a list of all tenant releases from local datacenter
    Parameters:
        ctx (dict): the context
    Returns:
        result (list): a linefeed delimited list of tenant to release pins, formatted for use in a haproxy map file
    '''
    pin_key = f"releases/{ctx.obj['ENVIRONMENT']}/tenant"
    pin_url = f"{ctx.obj['CONSUL_URL']}/v1/kv/{pin_key}?recurse=true"
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
        tenant = r['Key'].split('/')[-1]
        result.append(f"{tenant} {base64.b64decode(r['Value']).decode('ascii')}")
    return result 

def fetch_all_banned_rooms(ctx):
    '''
    get a list of all banned room names from local datacenter
    Parameters:
        ctx (dict): the context
    Returns:
        result (list): a linefeed delimited list of banned room names, formatted for use in a haproxy map file
    '''
    pin_key = f"bans/{ctx.obj['ENVIRONMENT']}/room"
    pin_url = f"{ctx.obj['CONSUL_URL']}/v1/kv/{pin_key}?recurse=true"
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
        tenant = r['Key'].split('/')[-1]
        result.append(f"{tenant} {base64.b64decode(r['Value']).decode('ascii')}")
    return result 

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
    if len(report['unchanged_ban']) > 0:
        if ctx.obj['DEBUG']:
            click.echo(f"## left {len(report['unchanged_ban'])} bans unchanged in the live map")
            for unchanged in report['unchanged_ban']:
                click.echo(unchanged)
    if len(report['add_ban']) > 0:
        click.echo(f"## added {len(report['add_ban'])} bans to the live map")
        if ctx.obj['DEBUG']:
            for added in report['add_ban']:
                click.echo(added)
    if len(report['update_ban']) > 0:
        click.echo(f"## updated {len(report['update_ban'])} bans in the live map")
        if ctx.obj['DEBUG']:
            for updated in report['update_ban']:
                click.echo(updated)
    if len(report['delete_ban']) > 0:
        click.echo(f"## deleted {len(report['delete_ban'])} bans in the live map")
        if ctx.obj['DEBUG']:
            for deleted in report['delete_ban']:
                click.echo(deleted)
    else:
        if ctx.obj['DEBUG']:
            click.echo("## took no action due to no changes found")


def sync_haproxy(ctx):
    ''' perform the sync itself '''
    report = {
        'add': [],        # added to haproxy because new in consul
        'update': [],     # updated on haproxy because changed in consul
        'delete': [],     # deleted from haproxy because it wasn't in consul
        'invalid': [],    # invalid pin in consul and ignored
        'persisted': [],  # persisted valid pin in haproxy despite invalid consul pin
        'unchanged': [],  # same in haproxy and consul; also includes 'persisted' pins
        'add_ban': [],        # added ban to haproxy because new in consul
        'update_ban': [],     # updated ban on haproxy because changed in consul
        'delete_ban': [],     # deleted ban from haproxy because it wasn't in consul
        'unchanged_ban': [],  # same ban in haproxy and consul
        'map_file_contents': '',
        'errors': [],
        'failed_early': False,
    }

    # get pins from consul, live map from haproxy, and live backends from haproxy
    haproxy_backends = [backend.name for backend in ctx.obj['HAPROXY_SOCKET'].backends()]

    consul_tenant_releases = fetch_all_tenant_releases(ctx)
    if not isinstance(consul_tenant_releases, list):
        click.echo("## WARNING: failed to fetch from consul; aborting")
        report['errors'].append('consul_fetch')
        report['failed_early'] = True
        return report
    consul_tenant_dict = { pin.split()[0]: pin.split()[1] for pin in consul_tenant_releases }

    consul_banned_rooms = fetch_all_banned_rooms(ctx)
    if not isinstance(consul_banned_rooms, list):
        click.echo("## WARNING: failed to fetch from consul; aborting")
        report['errors'].append('ban_consul_fetch')
        report['failed_early'] = True
        return report
    consul_ban_dict = { pin.split()[0]: pin.split()[1] for pin in consul_banned_rooms }

    try:
        haproxy_tenant_map = ctx.obj['HAPROXY_SOCKET'].show_map(ctx.obj['TENANT_MAP'])
    except OSError as exception:
        click.echo(f"## WARNING: failed get live haproxy map; aborting sync attempt\n{exception}")
        report['errors'].append('haproxy_socket')
        report['failed_early'] = True
        return report
    haproxy_tenant_dict = { pin.split()[1]: pin.split()[2] for pin in haproxy_tenant_map }

    try:
        haproxy_ban_map = ctx.obj['HAPROXY_SOCKET'].show_map(ctx.obj['BAN_MAP'])
    except OSError as exception:
        click.echo(f"## WARNING: failed get live haproxy ban map; aborting sync attempt\n{exception}")
        report['errors'].append('ban_haproxy_socket')
        report['failed_early'] = True
        return report
    haproxy_ban_dict = { pin.split()[1]: pin.split()[2] for pin in haproxy_ban_map }

    # check pins from consul against live backends for invalid entries
    for tenant in consul_tenant_dict.keys():
        if consul_tenant_dict[tenant] not in haproxy_backends:
            ## if there is an existing valid pin, persist it
            if tenant in haproxy_tenant_dict.keys() and haproxy_tenant_dict[tenant] in haproxy_backends:
                consul_tenant_dict[tenant] = haproxy_tenant_dict 
                report['persisted'].append(f"{tenant} {consul_tenant_dict[tenant]}")
            else:
                report['invalid'].append(f"{tenant} {consul_tenant_dict[tenant]}")

    # build the map file
    for invalid_tenant in report['invalid']:
        consul_tenant_dict.pop(invalid_tenant.split()[0])
    report['map_file_contents'] = "\n".join([f"{tenant} {consul_tenant_dict[tenant]}" for tenant in consul_tenant_dict.keys()])
    report['ban_map_file_contents'] = "\n".join([f"{room} {consul_ban_dict[room]}" for room in consul_ban_dict.keys()])

    # check live pins in haproxy and update/delete if needed, pops these out of the dict
    for tenant in haproxy_tenant_dict.keys():
        if tenant in consul_tenant_dict.keys():
            if haproxy_tenant_dict[tenant] == consul_tenant_dict[tenant]:
                report['unchanged'].append(f"{tenant} {haproxy_tenant_dict[tenant]}")
                consul_tenant_dict.pop(tenant)
            else:
                if not ctx.obj['DRY_RUN']:
                    success = ctx.obj['HAPROXY_SOCKET'].set_map(ctx.obj['TENANT_MAP'], tenant, consul_tenant_dict[tenant])
                    if not success:
                        click.echo("## failed to set_map")
                        report['errors'].append('haproxy_socket')
                report['update'].append(f"{tenant} {consul_tenant_dict[tenant]}")
                consul_tenant_dict.pop(tenant)
        else:
            # delete from the live haproxy map because there isn't a pin in consul
            if not ctx.obj['DRY_RUN']:
                success = ctx.obj['HAPROXY_SOCKET'].del_map(ctx.obj['TENANT_MAP'], tenant)
                if not success:
                    click.echo("## failed to set_map")
                    report['errors'].append('haproxy_socket')
            report['delete'].append(f"{tenant} {haproxy_tenant_dict[tenant]}")
    # remaining entries in consul_tenant_dict need to be added to the live haproxy map
    for tenant in consul_tenant_dict.keys():
        if not ctx.obj['DRY_RUN']:
            success = ctx.obj['HAPROXY_SOCKET'].add_map(ctx.obj['TENANT_MAP'], tenant, consul_tenant_dict[tenant])
            if not success:
                click.echo("## failed to set_map")
                report['errors'].append('haproxy_socket')
        report['add'].append(f"{tenant} {consul_tenant_dict[tenant]}")

    # check live bans in haproxy and update/delete if needed, pops these out of the dict
    for room in haproxy_ban_dict.keys():
        if room in consul_ban_dict.keys():
            if haproxy_ban_dict[tenant] == consul_ban_dict[room]:
                report['unchanged_ban'].append(f"{room} {haproxy_ban_dict[room]}")
                consul_ban_dict.pop(room)
            else:
                if not ctx.obj['DRY_RUN']:
                    success = ctx.obj['HAPROXY_SOCKET'].set_map(ctx.obj['BAN_MAP'], room, consul_ban_dict[room])
                    if not success:
                        click.echo("## failed to set_map")
                        report['errors'].append('ban_haproxy_socket')
                report['update_ban'].append(f"{room} {consul_ban_dict[room]}")
                consul_ban_dict.pop(room)
        else:
            # delete from the live haproxy map because there isn't a pin in consul
            if not ctx.obj['DRY_RUN']:
                success = ctx.obj['HAPROXY_SOCKET'].del_map(ctx.obj['BAN_MAP'], room)
                if not success:
                    click.echo("## failed to set_map")
                    report['errors'].append('ban_haproxy_socket')
            report['delete_ban'].append(f"{room} {consul_ban_dict[room]}")

    # remaining entries in consul_ban_dict need to be added to the live haproxy map
    for room in consul_ban_dict.keys():
        if not ctx.obj['DRY_RUN']:
            success = ctx.obj['HAPROXY_SOCKET'].add_map(ctx.obj['BAN_MAP'], room, consul_ban_dict[tenant])
            if not success:
                click.echo("## failed to set_map")
                report['errors'].append('haproxy_socket')
        report['add_ban'].append(f"{room} {consul_ban_dict[room]}")

    # update the map file, only if there have been changes
    if not ctx.obj['DRY_RUN']:
        if len(report['add']) > 0 or len(report['update']) > 0 or len(report['delete']) > 0:
            try:
                with open(ctx.obj['TENANT_MAP'], 'w', encoding="UTF-8") as tenant_map_file:
                    tenant_map_file.write(report['map_file_contents'])
            except OSError:
                report['errors'].append('map_file_write')

        if len(report['add_ban']) > 0 or len(report['update_ban']) > 0 or len(report['delete_ban']) > 0:
            try:
                with open(ctx.obj['BAN_MAP'], 'w', encoding="UTF-8") as ban_map_file:
                    ban_map_file.write(report['ban_map_file_contents'])
            except OSError:
                report['errors'].append('ban_map_file_write')

    return report

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
@click.option('--ban-map', 'ban_map', envvar=['BAN_MAP_PATH'], default='/etc/haproxy/maps/bans.map', show_default=True, help='path to banned room map file')
@click.option('--consul-url', '--url', 'consul_url', envvar=['CONSUL_URL'], default='http://localhost:8500', show_default=True, help='url of consul server')
@click.option('--environment', required=True, envvar=['ENVIRONMENT', 'HCV_ENVIRONMENT'], help='jitsi environment')
@click.option('--daemon', '-d', envvar=['DAEMON_MODE'], is_flag=True, help='run as a daemon')
@click.option('--tick_duration', envvar=['DAEMON_TICK_DURATION'], default=5, help='duration of ticker for daemon mode in seconds')
@click.option('--statsd', 'statsd_enabled', envvar=['STATSD_ENABLED'], is_flag=True, default=False, show_default=True, help='emit results to statsd')
@click.option('--debug', '-v', is_flag=True, envvar=['DEBUG'], help='verbose debug messages')
@click.option('--dry-run', 'dry_run', is_flag=True, help='leave map unchanged')
@click.pass_context
def sync(ctx, tenant_map, ban_map, consul_url, environment, daemon, tick_duration, statsd_enabled, debug, dry_run):
    ''' main click command '''
    ctx.ensure_object(dict)
    ctx.obj['CONSUL_URL'] = consul_url
    ctx.obj['ENVIRONMENT'] = environment
    ctx.obj['TENANT_MAP'] = tenant_map
    ctx.obj['BAN_MAP'] = ban_map
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
