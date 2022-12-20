#!/usr/bin/python


import json

# Oracle does not use multiple shards
# Create dummy shard details for now
def main():
    local_shard = 'standalone'
    facts = {
        'shard': local_shard
    }
    facts['shards'] = {local_shard: dict(facts)}

    print(json.dumps(facts))

if __name__ == '__main__':
    main()
