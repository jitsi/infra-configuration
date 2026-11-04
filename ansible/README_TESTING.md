# Ansible Role Testing

This document outlines the testing framework and approach for the Ansible roles in this repository.

## Overview

The testing framework uses [Molecule](https://molecule.readthedocs.io/) to test Ansible roles across different scenarios and platforms. The framework ensures that:

1. Roles have correct syntax
2. Roles can be applied successfully
3. Roles are idempotent (can be run multiple times without changing the result)
4. Roles produce the expected system state

## Prerequisites

To run the tests locally, you'll need:

```bash
# Install dependencies
pip install molecule molecule-docker ansible-lint pytest-testinfra

# For Docker driver
brew install docker-compose
```

## Test Structure

Each role may have multiple test scenarios, typically:

- `default`: Tests the role with standard parameters
- `oracle`: Tests the role with Oracle Cloud specific parameters
- Other platform-specific scenarios as needed

### Directory Structure

```
roles/
  common/
    molecule/
      default/
        molecule.yml    # Test configuration
        converge.yml    # Playbook to apply the role
        verify.yml      # Tests to validate the role worked correctly
      oracle/
        molecule.yml    # Oracle-specific test configuration
        converge.yml    # Oracle-specific apply playbook
        verify.yml      # Oracle-specific validation tests
```

## Running Tests

You can run tests using the provided script:

```bash
# Run all tests for all roles
./scripts/run-ansible-tests.sh

# Run tests for a specific role
./scripts/run-ansible-tests.sh common

# Run a specific scenario for a role
./scripts/run-ansible-tests.sh -s oracle common

# Just run the linting
./scripts/run-ansible-tests.sh --lint common

# List roles with tests
./scripts/run-ansible-tests.sh --list
```

## Test Phases

The Molecule tests run through the following phases:

1. **Lint**: Check code quality using ansible-lint
2. **Syntax**: Verify playbook syntax
3. **Create**: Create test containers
4. **Prepare**: Prepare the container for testing
5. **Converge**: Run the role against the container
6. **Idempotence**: Run the role again to verify no changes
7. **Verify**: Run tests to validate the container state
8. **Destroy**: Clean up test containers

## Writing Tests

### Verification Tests

Verification tests check that the role produces the expected state. They should verify:

1. Required packages are installed
2. Configuration files have the correct content
3. Services are running (if applicable)
4. The system behaves as expected

Example verification test in `verify.yml`:

```yaml
---
- name: Verify
  hosts: all
  become: true
  tasks:
    - name: Check if packages are installed
      ansible.builtin.package:
        name: "{{ item }}"
        state: present
      check_mode: true
      register: pkg_status
      failed_when: pkg_status.changed
      loop:
        - package1
        - package2
        
    - name: Check if configuration file exists
      ansible.builtin.stat:
        path: "/etc/myconfig.conf"
      register: config_file
      
    - name: Verify configuration file
      ansible.builtin.assert:
        that: config_file.stat.exists
```

## Continuous Integration

These tests are designed to run in a CI/CD pipeline. They validate that roles work properly across different scenarios before changes are merged.

## Best Practices

1. Write tests for all roles
2. Keep tests focused and concise
3. Test for both presence (things that should exist) and absence (things that shouldn't)
4. Use assertion messages to make test failures clear
5. Test roles across multiple platforms when possible
