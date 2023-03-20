variable "environment" {
    type = string
}

variable "dc" {
  type = string
}

variable "octo_region" {
    type=string
}

variable cloud_provider {
    type = string
    default = "oracle"
}

variable wavefront_proxy_server {
    type = string
    default = "localhost"
}


job "[JOB_NAME]" {
  region = "global"
  datacenters = [var.dc]

  type        = "system"

  meta {
    environment = "${var.environment}"
    octo_region = "${var.octo_region}"
    cloud_provider = "${var.cloud_provider}"
    wavefront_proxy_server = "${var.wavefront_proxy_server}"
  }

  // must have linux for network mode
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  group "telegraf" {
    count = 1

    network {
      mode = "host"
      port "telegraf-statsd" {
        static = 8125
      }
    }

    task "telegraf" {
      user = "telegraf:997"
      driver = "docker"
      meta {
      }
      config {
        privileged = true
        image        = "telegraf:latest"
        ports = ["telegraf-statsd"]
        volumes = ["/:/hostfs", "local/telegraf.conf:/etc/telegraf/telegraf.conf", "/var/run/docker.sock:/var/run/docker.sock"]
        hostname = "${attr.unique.hostname}"
      }
      env {
	    HOST_ETC = "/hostfs/etc"
	    HOST_PROC = "/hostfs/proc"
	    HOST_SYS = "/hostfs/sys"
	    HOST_VAR = "/hostfs/var"
	    HOST_RUN = "/hostfs/run"
	    HOST_MOUNT_PREFIX = "/hostfs"
      }

      template {
        data = <<EOF
[agent]
  interval = "60s"
  round_interval = false
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "60s"
  flush_jitter = "0s"
  precision = ""
  debug = true
  quiet = false
  omit_hostname = false

[[inputs.nomad]]
  url = "http://{{ env "NOMAD_IP_telegraf_statsd" }}:4646"

[[inputs.docker]]
  endpoint = "unix:///var/run/docker.sock"

[[inputs.cpu]]
  percpu = false
  totalcpu = true
  collect_cpu_time = false
  report_active = false
  fielddrop = ["time_*"]
  fieldpass = ["usage_system*", "usage_user*", "usage_iowait*", "usage_idle*", "usage_steal*"]

[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "overlay", "aufs", "squashfs", "nfs", "nfs4"]
  fieldpass = ["used_percent", "free", "used", "total"]

[[inputs.diskio]]
  fieldpass = ["read_time", "write_time"]

[[inputs.mem]]
  fieldpass = [ "active", "available", "buffered", "cached", "free", "total",  "used" ]

[[inputs.net]]
  fieldpass = ["bytes*","drop*","packets*","err*","tcp*","udp*"]

[[inputs.processes]]
  fieldpass = ["blocked", "idle", "paging", "running", "total*"]

[[inputs.swap]]
  fieldpass = ["total", "used"]

[[inputs.system]]
  fieldpass = ["load*"]

[[inputs.linux_sysctl_fs]]

[[inputs.statsd]]
  service_address = ":{{ env "NOMAD_HOST_PORT_telegraf_statsd" }}"
  delete_gauges = true
  delete_counters = true
  delete_sets = true
  delete_timings = true
  percentiles = [90]
  metric_separator = "_"
  allowed_pending_messages = 10000
  percentile_limit = 1000
  datadog_extensions = true

[[inputs.prometheus]]
{{ range service "consul" }}
{{ scratch.Set "consul_server" .Address }}
{{ end }}
    # urls = ["http://{{ env "NOMAD_IP_jicofo_http" }}:{{ env "NOMAD_HOST_PORT_jicofo_http" }}/metrics","http://{{ env "NOMAD_IP_prosody_http" }}:{{ env "NOMAD_HOST_PORT_prosody_http" }}/metrics","http://{{ env "NOMAD_IP_signal_sidecar_http" }}:{{ env "NOMAD_HOST_PORT_signal_sidecar_http" }}/metrics"]
  [inputs.prometheus.consul]
    enabled = true
    agent = "{{ scratch.Get "consul_server" }}:8500"
    query_interval = "5m"
    [[inputs.prometheus.consul.query]]
      name = "jicofo"
      tag = "ip-{{ env "NOMAD_IP_telegraf_statsd" }}"
      url = 'http://{{"{{"}}if ne .ServiceAddress ""}}{{"{{"}}.ServiceAddress}}{{"{{"}}else}}{{"{{"}}.Address}}{{"{{"}}end}}:{{"{{"}}.ServicePort}}/{{"{{"}}with .ServiceMeta.metrics_path}}{{"{{"}}.}}{{"{{"}}else}}metrics{{"{{"}}end}}'
      [inputs.prometheus.consul.query.tags]
        host = "{{"{{"}}.Node}}"
        shard = "{{"{{"}}with .ServiceMeta.shard}}{{"{{"}}.}}{{"{{"}}else}}shard{{"{{"}}end}}"
        release_number = "{{"{{"}}with .ServiceMeta.release_number}}{{"{{"}}.}}{{"{{"}}else}}0{{"{{"}}end}}"
        shard-role = "core"
        role = "core"
    [[inputs.prometheus.consul.query]]
      name = "prosody-http"
      tag = "ip-{{ env "NOMAD_IP_telegraf_statsd" }}"
      url = 'http://{{"{{"}}if ne .ServiceAddress ""}}{{"{{"}}.ServiceAddress}}{{"{{"}}else}}{{"{{"}}.Address}}{{"{{"}}end}}:{{"{{"}}.ServicePort}}/{{"{{"}}with .ServiceMeta.metrics_path}}{{"{{"}}.}}{{"{{"}}else}}metrics{{"{{"}}end}}'
      [inputs.prometheus.consul.query.tags]
        host = "{{"{{"}}.Node}}"
        shard = "{{"{{"}}with .ServiceMeta.shard}}{{"{{"}}.}}{{"{{"}}else}}shard{{"{{"}}end}}"
        release_number = "{{"{{"}}with .ServiceMeta.release_number}}{{"{{"}}.}}{{"{{"}}else}}0{{"{{"}}end}}"
        shard-role = "core"
        role = "core"
    [[inputs.prometheus.consul.query]]
      name = "signal-sidecar"
      tag = "ip-{{ env "NOMAD_IP_telegraf_statsd" }}"
      url = 'http://{{"{{"}}if ne .ServiceAddress ""}}{{"{{"}}.ServiceAddress}}{{"{{"}}else}}{{"{{"}}.Address}}{{"{{"}}end}}:{{"{{"}}.ServicePort}}/{{"{{"}}with .ServiceMeta.metrics_path}}{{"{{"}}.}}{{"{{"}}else}}metrics{{"{{"}}end}}'
      [inputs.prometheus.consul.query.tags]
        host = "{{"{{"}}.Node}}"
        shard = "{{"{{"}}with .ServiceMeta.shard}}{{"{{"}}.}}{{"{{"}}else}}shard{{"{{"}}end}}"
        release_number = "{{"{{"}}with .ServiceMeta.release_number}}{{"{{"}}.}}{{"{{"}}else}}0{{"{{"}}end}}"
        shard-role = "core"
        role = "core"

[[outputs.wavefront]]
  url = "http://{{ env "NOMAD_META_wavefront_proxy_server" }}:2878"
  metric_separator = "."
  source_override = ["hostname", "snmp_host", "node_host"]
  convert_paths = true
  use_regex = false

[global_tags]
  environment = "{{ env "NOMAD_META_environment" }}"
  region = "{{ env "NOMAD_META_octo_region" }}"
  cloud = "{{  env "NOMAD_META_cloud_provider" }}"
  cloud_provider = "{{ env "NOMAD_META_cloud_provider" }}"

EOF
        destination = "local/telegraf.conf"
      }
    }
  }
}