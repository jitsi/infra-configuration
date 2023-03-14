variable "dc" {
  type = string
}
variable "dns_zone" {
  type = string
  default = "jitsi.net"
}

job "jigasi-haproxy" {
  region = "global"
  datacenters = [var.dc]

  type        = "service"

  // must have linux for network mode
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  group "haproxy" {
    count = 2
    # All groups in this job should be scheduled on different hosts.
    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    network {
      port "http" {
      }

      port "admin" {
      }
    }

    service {
      name = "jigasi-haproxy"
      tags = ["urlprefix-${var.dc}-jigasi-selector.${var.dns_zone}/"]
      port = "http"

      check {
        name     = "alive"
        type     = "tcp"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "haproxy" {
      driver = "docker"

      config {
        image        = "haproxy:2.6"
        network_mode = "host"

        volumes = [
          "local/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg",
        ]
      }

      template {
        data = <<EOF
defaults
  log  global
  mode  http
  option httplog
  option log-health-checks
  option dontlognull
  option forwardfor
  option http-server-close
  option redispatch

  maxconn 2000
  retries  3
  timeout connect 10s
  timeout client  3m
  timeout server  3m
  timeout client-fin 50s
  timeout tunnel  1h

resolvers mydns
    nameserver dns1 127.0.0.1:8600
    accepted_payload_size 8192 # allow larger DNS payloads
    hold valid 5s

# setup haproxy stats ui and a health check uri for haproxy itself
listen admin
  bind *:{{ env "NOMAD_PORT_admin" }}
  monitor-uri /haproxy_health
  stats enable
  stats auth admin:admin
  stats uri /haproxy_stats


frontend www-http
   bind *:{{ env "NOMAD_PORT_http" }}
   acl bad_guy_wordpress hdr_sub(User-Agent) -i wordpress
   http-request deny if bad_guy_wordpress
   default_backend jigasi-be

backend jigasi-be

    balance roundrobin
  option httpchk GET /about/health
  default-server inter 10s fastinter 2s fall 3 rise 5 weight 255 agent-check agent-inter 5s agent-port 7070
  # list all the nodes via DNS
  server-template jig 500 {{ env "meta.environment" }}.jigasi.service.consul:80 resolvers mydns init-addr none inter 10s fastinter 2s fall 3 rise 5 weight 255 agent-check agent-inter 5s agent-port 7070
EOF

        destination = "local/haproxy.cfg"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}