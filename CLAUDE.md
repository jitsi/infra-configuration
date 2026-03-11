# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Infrastructure as Code (Ansible-based) for deploying and managing a distributed Jitsi video conferencing platform across multiple cloud providers (AWS and Oracle Cloud). The infrastructure uses a multi-shard architecture with HAProxy load balancing, Consul service discovery, and Nomad container orchestration.

## Architecture

### Multi-Shard Design
- **Core/Signal nodes**: Run Prosody (XMPP), Jicofo (conference focus), and Jitsi Meet web frontend
- **JVB (Jitsi Videobridge) nodes**: Handle media routing and bridging
- **HAProxy mesh**: Global load balancers that route conference traffic to appropriate shards using stick tables synchronized across regions
- **Jibri nodes**: Recording and streaming infrastructure
- **Jigasi nodes**: SIP gateway for telephone integration
- **Consul**: Service discovery and configuration management
- **Nomad**: Container orchestration for various services

### Multi-Cloud Support
- Primary: Oracle Cloud (using Instance Pools)
- Secondary: AWS (using EC2, ASGs)
- Cloud provider abstraction via `cloud_provider` variable (aws/oracle)

### Configuration Management
- Main configuration: `config/vars.yml` (symlinked from private customizations repo)
- Environment-specific: `sites/$ENVIRONMENT/vars.yml`
- Secrets: `secrets/*.yml` (vault-encrypted)
- Templates: Jinja2 templates with Consul-template for runtime updates

## Directory Structure

- `ansible/` - All Ansible playbooks and roles
  - `ansible/*.yml` - 61+ playbooks for building images and configuring services
  - `ansible/roles/` - 137+ Ansible roles for various components
  - `ansible/secrets/` - Vault-encrypted secrets (not in git)
  - `ansible/config/` - Symlink to private customizations repo
  - `ansible/sites/` - Symlink to environment-specific configs
- `scripts/` - Utility scripts
  - `hcvlib.py` - Core Python library for cloud provider interactions (AWS/Oracle)
  - `node.py` - Node discovery and inventory management
  - `run-ansible-cmd.sh` - Wrapper for running ad-hoc Ansible commands
  - `configure-standalone-oracle.sh` - Deploy standalone Jitsi instance
- `ansible.cfg` - Ansible configuration with fact caching, vault integration

## Key Ansible Roles

**Jitsi Components:**
- `prosody` - XMPP signaling server
- `jicofo` - Conference focus/control
- `jitsi-videobridge` - Media bridge
- `jitsi-meet` - Web frontend
- `jigasi` - SIP gateway
- `jibri-*` - Recording infrastructure (5 roles)
- `prosody-egress` - Recording/egress support

**Infrastructure:**
- `consul-*` - Service discovery (11 roles: server, agent, template, etc.)
- `haproxy*` - Load balancing (6 roles including `hcv-haproxy-configure`)
- `nomad*` - Container orchestration (3 roles)
- `docker*` - Container runtime (4 roles)

**System:**
- `common` - Base system configuration
- `sshusers`, `sshmfa` - SSH access management
- `iptables*` - Firewall rules (multiple specialized roles)
- `wavefront`, `vector` - Observability
- `vault` - Secrets management

## Important Patterns

### Playbook Structure
1. Load secrets from `secrets/*.yml`
2. Load config from `config/vars.yml` and `sites/$ENVIRONMENT/vars.yml`
3. Pre-tasks: Clean up old repos, gather cloud metadata, set facts
4. Roles: Apply configuration in dependency order
5. Post-tasks: Restart services as needed

### Cloud Provider Detection
- Playbooks use `cloud_provider` variable (aws/oracle)
- Oracle instances fetch metadata from `http://169.254.169.254/opc/v1/`
- AWS instances use `amazon.aws.ec2_metadata_facts`
- Conditional role application based on provider

### Version Management
- Jitsi component versions can be pinned via environment variables
- Default to latest with `*` wildcard
- Version format examples:
  - JVB: `2.1-123-g1234567-1` or `*`
  - Jicofo: `1.0-456-1` or `*`
  - Meet: `1.0.7890-1` or `*`

### HAProxy Operations
- HAProxy uses stick tables to map conferences to shards
- Global mesh synchronized via peer protocol
- Tenant pinning maps tenants to specific releases via `/etc/haproxy/maps/tenant.map`
- Live release defined in `/etc/haproxy/maps/live.map`
- `haproxy-reload` job must run when shards are added/removed
- `haproxy-recycle` job replaces instances (breaks websocket connections)

### Secrets and Vault
- All secrets in `ansible/secrets/*.yml` are encrypted with Ansible Vault
- Vault password file: `.vault-password.txt` (not in git)
- Always use `--vault-password-file .vault-password.txt` with playbooks

## Configuration Files

**ansible.cfg:**
- Fact caching enabled in `.facts/` directory (24h TTL)
- SSH connection pooling (15m persist)
- Custom SSH config: `config/ssh-vpn.config`
- Vault password file: `.vault-password.txt`

**Environment variables for scripts:**
- `ENVIRONMENT` - Environment name (required)
- `ORACLE_REGION` - Oracle cloud region (required for Oracle deployments)
- `ROLE` - Node role for inventory scripts
- `ANSIBLE_SSH_USER` - SSH user (defaults to current user)
- `ANSIBLE_TAGS` - Specific tags to run (defaults to "all")

## HAProxy Deployment Guide

See `README_HAPROXY.md` for detailed HAProxy operations including:
- Deploying new regions (requires consul KV: `consul kv put releases/$ENV/live release-XXXX`)
- Configuration rebuilds when shards change
- Upgrade checklist and verification steps
- Tenant pinning and live release management
- Split brain monitoring and patching

## Development Workflow

1. **Make changes to roles/playbooks**
2. **Lint with ansible-lint** (optional but recommended)
3. **Test on standalone instance first** using `configure-standalone-oracle.sh`
4. **Deploy to target environment** using appropriate configure playbook
5. **Verify with monitoring** (Wavefront dashboards, Consul health checks)
6. **For HAProxy changes**: Run `haproxy-reload` job after configuration updates

## Notes

- This repository depends on a private customizations repository (symlinked as `config/` and `sites/`)
- Some external roles are included as git submodules (docker, haproxy, consul-template, etc.)
- The `hcvlib.py` library provides core functionality for AWS and Oracle Cloud API interactions
- Build playbooks create AMIs/images, configure playbooks provision running instances
- Oracle Cloud uses OCI SDK, AWS uses boto3
