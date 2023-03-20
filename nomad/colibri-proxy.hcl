variable "environment" {
    type = string
}

variable "domain" {
    type = string
}

variable "dc" {
  type = string
}

variable colibri_proxy_second_octet_regexp {
    type = string
        default = "5[2-3]"
}

variable colibri_proxy_third_octet_regexp {
    type = string
        default = "6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7]"
}

variable colibri_proxy_fourth_octet_regexp {
    type = string
        default = "25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?"
}

job "[JOB_NAME]" {
  region = "global"
  datacenters = [var.dc]

  type        = "service"

  meta {
    domain = "${var.domain}"
    environment = "${var.environment}"
  }

  // must have linux for network mode
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  group "colibri-proxy" {
    count = 1

    constraint {
      attribute  = "${meta.pool_type}"
      value     = "general"
    }
    network {
      port "nginx-colibri-proxy" {
      }
    }
    service {
      name = "colibri-proxy"
      tags = ["${var.domain}","urlprefix-${var.domain}/colibri-ws","urlprefix-${var.domain}/colibri-relay-ws"]

      port = "nginx-colibri-proxy"

      check {
        name     = "health"
        type     = "http"
        path     = "/"
        port     = "nginx-colibri-proxy"
        interval = "10s"
        timeout  = "2s"
      }
    }
    task "colibri-proxy" {
      driver = "docker"
      config {
        image        = "nginx:latest"
        ports = ["nginx-colibri-proxy"]
        volumes = ["local/nginx-conf.d:/etc/nginx/conf.d"]
      }
      meta {
        SECOND_OCTET_REGEXP = "${var.colibri_proxy_second_octet_regexp}"
        THIRD_OCTET_REGEXP = "${var.colibri_proxy_third_octet_regexp}"
        FOURTH_OCTET_REGEXP = "${var.colibri_proxy_fourth_octet_regexp}"
      }
      env {
        NGINX_PORT = "${NOMAD_HOST_PORT_nginx_colibri_proxy}"
      }

      template {
        data = <<EOF

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen {{ env "NOMAD_HOST_PORT_nginx_colibri_proxy" }} default_server;
    listen  [::]:{{ env "NOMAD_HOST_PORT_nginx_colibri_proxy" }} default_server;
    server_name  {{ env "NOMAD_META_domain" }};

    #access_log  /var/log/nginx/host.access.log  main;

    root   /usr/share/nginx/html;

    location ~ ^/colibri-ws/jvb-({{ env "NOMAD_META_SECOND_OCTET_REGEXP" }})-({{ env "NOMAD_META_THIRD_OCTET_REGEXP" }})-({{ env "NOMAD_META_FOURTH_OCTET_REGEXP" }})(/?)(.*) {
        proxy_pass https://10.$1.$2.$3:443/colibri-ws/jvb-$1-$2-$3/$5$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host {{ env "NOMAD_META_domain" }};
        tcp_nodelay on;
    }


    location ~ ^/colibri-relay-ws/jvb-({{ env "NOMAD_META_SECOND_OCTET_REGEXP" }})-({{ env "NOMAD_META_THIRD_OCTET_REGEXP" }})-({{ env "NOMAD_META_FOURTH_OCTET_REGEXP" }})(/?)(.*) {
        proxy_pass https://10.$1.$2.$3:443/colibri-relay-ws/jvb-$1-$2-$3/$5$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host {{ env "NOMAD_META_domain" }};
        tcp_nodelay on;
    }
}
EOF
        destination = "local/nginx-conf.d/default.conf"
        }
    }
  }
}