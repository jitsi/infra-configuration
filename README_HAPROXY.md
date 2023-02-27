# haproxy and the jitsi ingress

## haproxy for jitsi shards

HAProxy is globally deployed on Jitsi edge nodes to ensure that signaling
traffic for a conference reaches the appropriate shard. There is a global mesh
of haproxies per
envrionment with usually two deployed in an instance pool per region.

HAProxy stick tables are used to map conference names to shards. These are
synchronized across the global mesh. `monitor haproxy` jobs runs on jenkins
to check for split brains and patch them across the fleet as needed

HAProxies rely on consul service discovery to find shards and identify them as
backends.

### deploying haproxy

For an entirely new region, consul needs to know the current live (GA) release.
Do this by going to a consul server in the region/environment and create an
entry in the kv store, e.g.,
`consul kv put releases/stage-8x8/live release-3629`

Now use the `haproxy-create-release` job to build new CloudFormation or
Terraform stacks:
* https://jenkins.jitsi.net/job/haproxy-create-release/

This job is also used to build new images ahead of a `haproxy-recyle`, which is
used to replace existing HAProxy instances with fresh instances on the latest
release created for the region/environment (*CURRENTLY AWS-ONLY*).
* https://jenkins.jitsi.net/job/haproxy-recycle/

The recycle job adds instances to the ASG (OCI future: Instance Pool) that run
the new release, allows them to mesh with the old instances, then tears down
the old instnaces.

Given that this job will potentially disrupt all traffic for an environment, it
can be run by hand from the jenkins machine using the `SCALE_UP_ONLY` and
`SCALE_DOWN_ONLY` flags. By scaling up only, one can look more closely at
whether or not the mesh is behaving properly before scaling down the old
instances.

### configuring haproxy

The HAProxy configuration files are built using ansible. Since this includes a
list of shards in an environment, this means that they must be rebuilt every
time shards are added or deleted from the environment. The `haproxy-reload` job
is used to refresh HAProxy configurations across the mesh:
* https://jenkins.jitsi.net/job/haproxy-reload

Most HAProxy configuration is in the `hcv-haproxy-configure` role.

### haproxy upgrade checklist

* Is the haproxy version what you expect?
    * `haproxy -v`
* Do the ASGs or Instance Pool dashboards show the proper number of instances?
* Have recent `monitor haproxy` job runs resulted in any split brains?
    * check [Split Brain alarms in Cloudwatch](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#alarmsV2:?~(search~'Split))
* Do all of the haproxies show each other as peers and have the stick table?
    * `ssh-jitsi [haproxy]`
    * `echo "show peers" | sudo -u haproxy socat stdio /var/run/haproxy/admin.sock | grep addr | grep haproxy`
    * `echo "show table nodes" | sudo -u haproxy socat stdio /var/run/haproxy/admin.sock`
* Is the tenant pin service working properly on the haproxies?
    * `sudo service tenant-pin status`
* Are haproxies behaving as expected in the wavefront dashboard?
    * https://metrics.wavefront.com/u/P6bjgLNKz2?t=8x8 

### live release

By default, HAProxy forwards traffic to the live (aka GA) release. It reads the
value in the map at `/etc/haproxy/maps/live.map` and that release backend is the
default backend that HAProxy traffic is sent to.

### tenant pinning

HAProxy enforces tenant pins to releases at the network ingress based on the
contents of `/etc/haproxy/maps/tenant.map`.

This map is maintained by the `tenant-pin` service, which uses the
`haproxy_tenant_sync.py` script to scrape tenant pins from the consul key-value
store. If there is a problem with this service, tenant pinning may get out of
date.

## haproxy and jigasi

*TBD*