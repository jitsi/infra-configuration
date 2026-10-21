#!/bin/bash
# run-ansible-tests.sh
# Simple script to run Molecule tests on all roles or a specific role

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to run molecule test on a role
run_test() {
    local role=$1
    local scenario=${2:-default}
    
    echo -e "${YELLOW}Testing role: ${role} (scenario: ${scenario})${NC}"
    
    cd "${ANSIBLE_ROLES_PATH}/${role}"
    
    if [ ! -d "molecule/${scenario}" ]; then
        echo -e "${RED}No molecule/${scenario} directory found in ${role} role${NC}"
        return 1
    fi
    
    echo "Running molecule test for ${role}..."
    if molecule test -s "${scenario}"; then
        echo -e "${GREEN}✓ Role ${role} passed all tests (scenario: ${scenario})${NC}"
        return 0
    else
        echo -e "${RED}✗ Role ${role} failed tests (scenario: ${scenario})${NC}"
        return 1
    fi
}

# Function to run ansible-lint on a role
run_lint() {
    local role=$1
    
    echo -e "${YELLOW}Linting role: ${role}${NC}"
    
    cd "${ANSIBLE_ROLES_PATH}/${role}"
    
    if ansible-lint; then
        echo -e "${GREEN}✓ Role ${role} passed linting${NC}"
        return 0
    else
        echo -e "${RED}✗ Role ${role} failed linting${NC}"
        return 1
    fi
}

# Function to list all roles with molecule tests
list_testable_roles() {
    find "${ANSIBLE_ROLES_PATH}" -name "molecule" -type d | sed 's|/molecule$||' | sort
}

# Function to list all scenarios for a role
list_scenarios() {
    local role=$1
    find "${ANSIBLE_ROLES_PATH}/${role}/molecule" -maxdepth 1 -mindepth 1 -type d | grep -v '_shared' | xargs -n1 basename
}

# Function to run syntax check
run_syntax_check() {
    local playbook=$1
    
    echo -e "${YELLOW}Syntax checking playbook: ${playbook}${NC}"
    
    if ansible-playbook --syntax-check "${playbook}"; then
        echo -e "${GREEN}✓ Playbook ${playbook} passed syntax check${NC}"
        return 0
    else
        echo -e "${RED}✗ Playbook ${playbook} failed syntax check${NC}"
        return 1
    fi
}

# Path to ansible roles
ANSIBLE_ROLES_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../ansible/roles"

# Help message
show_help() {
    echo "Usage: $0 [options] [role_name]"
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message"
    echo "  -l, --list         List all roles with molecule tests"
    echo "  -s, --scenario     Specify a molecule scenario (default: default)"
    echo "  --lint             Run only ansible-lint on the role"
    echo "  --syntax           Run syntax check on all playbooks"
    echo ""
    echo "Examples:"
    echo "  $0                 Run all molecule tests for all roles"
    echo "  $0 common          Run molecule tests for the common role"
    echo "  $0 -s oracle common Run oracle scenario tests for the common role"
    echo "  $0 --lint common   Run only ansible-lint on the common role"
}

# Parse command-line arguments
SCENARIO="default"
LINT_ONLY=false
SYNTAX_CHECK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -l|--list)
            echo "Roles with molecule tests:"
            list_testable_roles | xargs -n1 basename
            exit 0
            ;;
        -s|--scenario)
            SCENARIO="$2"
            shift 2
            ;;
        --lint)
            LINT_ONLY=true
            shift
            ;;
        --syntax)
            SYNTAX_CHECK=true
            shift
            ;;
        *)
            ROLE="$1"
            shift
            ;;
    esac
done

# If --syntax flag is set, run syntax check on all playbooks
if [ "$SYNTAX_CHECK" = true ]; then
    PLAYBOOKS=$(find "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ansible" -name "*.yml" -type f | grep -v "roles/")
    
    for playbook in $PLAYBOOKS; do
        run_syntax_check "$playbook"
    done
    
    exit 0
fi

# If a specific role is given
if [ -n "$ROLE" ]; then
    # If --lint flag is set, only run ansible-lint
    if [ "$LINT_ONLY" = true ]; then
        run_lint "$ROLE"
    else
        # List available scenarios if the role exists
        if [ -d "${ANSIBLE_ROLES_PATH}/${ROLE}/molecule" ]; then
            echo "Available scenarios for ${ROLE}:"
            list_scenarios "$ROLE"
            
            run_test "$ROLE" "$SCENARIO"
        else
            echo -e "${RED}Error: Role ${ROLE} not found or no molecule tests available${NC}"
            exit 1
        fi
    fi
else
    # Run all tests for all roles
    FAILED_ROLES=()
    
    for role_path in $(list_testable_roles); do
        role=$(basename "$role_path")
        
        if [ "$LINT_ONLY" = true ]; then
            if ! run_lint "$role"; then
                FAILED_ROLES+=("$role")
            fi
        else
            for scenario in $(list_scenarios "$role"); do
                if ! run_test "$role" "$scenario"; then
                    FAILED_ROLES+=("$role ($scenario)")
                fi
            done
        fi
    done
    
    if [ ${#FAILED_ROLES[@]} -eq 0 ]; then
        echo -e "${GREEN}All roles passed all tests!${NC}"
    else
        echo -e "${RED}The following roles failed tests:${NC}"
        printf "  %s\n" "${FAILED_ROLES[@]}"
        exit 1
    fi
fi
