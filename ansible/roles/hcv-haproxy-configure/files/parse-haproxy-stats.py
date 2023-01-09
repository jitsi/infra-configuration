#!/usr/bin/env python


import sys, json

from pprint import pprint

import os

expire_threshhold=250000

def usage():
    print("Usage:")
    print(sys.argv[0] +' <stats file path> <table file path>')
    return  1
def limit_active_rooms(expire_by_room):
    active_rooms = [x for x in list(expire_by_room.keys()) if int(expire_by_room[x])>expire_threshhold ]
    return active_rooms

def load_table_file(tfile):
    f = open(tfile, 'r')
    header=f.readline()
    file_info = {}
    servers_by_room = {}
    expire_by_room = {}
    rooms_by_server = {}
    for line in f:
        #line looks like "0x22cd484: key=leecee use=0 exp=299198 server_id=6518987"
        if len(line.strip())>0:
            (tkey,room,use,expires,server) = [ x.split('=')[-1].strip() for x in line.split(' ') ]
            servers_by_room[room]=server
            expire_by_room[room]=expires
            if not server in rooms_by_server:
                rooms_by_server[server] = []
            rooms_by_server[server].append(room)

    file_info['filename'] = tfile
    file_info['servers_by_room'] = servers_by_room
    file_info['rooms_by_server'] = rooms_by_server
    file_info['expire_by_room'] = expire_by_room
    file_info['active_rooms'] = limit_active_rooms(expire_by_room)

    return file_info



def load_stats_file(sfile):
    f = open(sfile, 'r')
    header_line=f.readline()
    headers=[ x for x in header_line[2:].strip().split(',') if len(x)>0 ]
    stats_info = {}
    stats_lines = []
    for line in f:
        stats_line={}
        line_split=line.strip().split(',')
        if len(line_split)>1:
            stats_line=dict(list(zip(headers,line_split)))
            stats_lines.append(stats_line)

    stats_info['frontends'] = []
    stats_info['backends'] = []
    stats_info['servers'] = []
    stats_info['frontend_stats'] = {}
    stats_info['backend_stats'] = {}
    stats_info['server_stats'] = {}

    for sline in stats_lines:
        if sline['svname']=='FRONTEND':
            if sline['pxname'] not in stats_info['frontends']:
                stats_info['frontends'].append(sline['pxname'])
                stats_info['frontend_stats'][sline['pxname']]=sline
        elif sline['svname']=='BACKEND':
            if sline['pxname'] not in stats_info['backends']:
                stats_info['backends'].append(sline['pxname'])
                stats_info['backend_stats'][sline['pxname']]= sline
        else:
            if sline['sid'] not in stats_info['servers']:
                stats_info['servers'].append(sline['sid'])
            stats_info['server_stats'][sline['sid']]=sline
#    stats_info['stats_lines'] = stats_lines
#    pprint(stats_info)

    return stats_info



if __name__ == "__main__":

  if len(sys.argv) > 2:
      stats_file_path = sys.argv[1]
      table_file_path = sys.argv[2]
  else:
      usage()
      exit(1)

  global_stats = load_stats_file(stats_file_path)
  table_stats = load_table_file(table_file_path)

  print(json.dumps({'global':global_stats,'table_stats':table_stats}))