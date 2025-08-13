# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the infra-configuration repository containing Ansible automation for configuring Jitsi Meet infrastructure components. It manages deployment and configuration of distributed Jitsi services including video bridges (JVB), conferencing focus (Jicofo), Jigasi (SIP gateway), HAProxy load balancers, and supporting infrastructure like Consul, Prosody XMPP servers, and monitoring systems.

## Usage Modes

This repository operates in three distinct modes:

### Operator Mode
Scripts are run manually from a workstation to make changes to systems. Requires a full environment with all proper tools installed (Ansible, cloud CLI tools, SSH keys, vault passwords, etc.). Used for manual infrastructure operations and troubleshooting.

### Jenkins Mode  
Repository is checked out during Jenkins jobs and scripts are executed by Jenkinsfile operations. Jenkins handles tool dependencies and credentials. Used for automated deployments, configuration updates, and scheduled maintenance tasks.

### Boot Mode
Repository is checked out on a bare VM and used to bootstrap the VM to its intended role and configuration. The VM pulls the repo and runs local configuration scripts to self-provision. Used during instance launch and auto-scaling operations.

## Key Commands

### Testing and Validation
- `scripts/check-ansible-syntax.sh` - Validate Ansible playbook syntax
- `scripts/run-ansible-tests.sh` - Experimental role testing (not required for workflow)
- `ansible-playbook ansible/test-all-roles.yml` - Experimental role testing (not required for workflow)

### Configuration Management
- `scripts/configure-standalone.sh` - Configure standalone Jitsi installations on AWS
- `scripts/configure-standalone-oracle.sh` - Configure Oracle Cloud standalone installations
- `scripts/configure-jitsi-repo.sh` - Configure Jitsi package repositories
- `scripts/configure-users.sh` - Configure system users and SSH access

### Version Management
- `scripts/get-latest-jitsi-versions.sh` - Update Jitsi component versions in build_versions.properties

### Infrastructure Operations
- HAProxy operations: `haproxy-reload-remote.yml`, `haproxy-status.yml`, `haproxy-set-release-ga.yml`
- Service management: `start/stop-consul-services.yml`, `start/stop-shard-services.yml`

## Architecture Overview

### Service Components
- **JVB (Jitsi Video Bridge)**: Media relay servers, auto-scaling with graceful shutdown
- **Jicofo**: Conference focus component managing sessions
- **Jigasi**: SIP/telephony gateway for PSTN integration
- **Prosody**: XMPP server handling signaling
- **HAProxy**: Load balancer with stick tables for shard routing
- **Consul**: Service discovery and KV store for configuration
- **Jibri**: Recording and streaming service (Docker and Java variants)

### Infrastructure Patterns
- **Sharding**: Conference traffic routed to specific backend shards via HAProxy stick tables
- **Service Discovery**: Consul-based registration and health checking
- **Cloud Integration**: AWS and Oracle Cloud support with instance metadata and autoscaling
- **Configuration Management**: Template-driven with Ansible and consul-template
- **Graceful Operations**: Termination handlers for clean service shutdown

### Key Configuration Files
- `ansible.cfg` - Ansible configuration with vault password and SSH settings
- `build_versions.properties` - Component version specifications
- Various `.inventory` files for different environments (prod, stage, etc.)
- `ansible/vars/` - Environment-specific variables

### Directory Structure
- `ansible/roles/` - Ansible roles for each service component
- `scripts/` - Operational shell scripts
- `sites/` - Site-specific configurations
- Root-level `.inventory` files for environment targeting

### Testing Framework
Molecule testing is experimental and not fully implemented across all roles. Testing infrastructure exists but is not required for successful workflow. Test inventory files exist in some roles under `tests/inventory`.

### Multi-Cloud Support
Supports both AWS and Oracle Cloud deployments with cloud-specific scripts and configurations (files ending in `-oracle`).