#!/bin/bash
# check-ansible-syntax.sh
# Quick script to validate the syntax of all Ansible playbooks in the repo

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ANSIBLE_DIR="${REPO_ROOT}/ansible"

# Find all YAML files that are likely playbooks
find_playbooks() {
  find "${ANSIBLE_DIR}" -name "*.yml" -type f | grep -v "/roles/" | grep -v "/molecule/"
}

# Check syntax on a single playbook
check_playbook() {
  local playbook=$1
  
  echo -e "${YELLOW}Checking syntax for ${playbook}${NC}"
  
  if ansible-playbook --syntax-check "${playbook}"; then
    echo -e "${GREEN}✓ ${playbook} - Syntax OK${NC}"
    return 0
  else
    echo -e "${RED}✗ ${playbook} - Syntax Error${NC}"
    return 1
  fi
}

# Main function
main() {
  local playbooks=$(find_playbooks)
  local failed_playbooks=()
  local success_count=0
  local total_count=0
  
  echo "Found $(echo "${playbooks}" | wc -l | tr -d ' ') playbooks to check"
  
  for playbook in ${playbooks}; do
    ((total_count++))
    if check_playbook "${playbook}"; then
      ((success_count++))
    else
      failed_playbooks+=("${playbook}")
    fi
  done
  
  echo ""
  echo "====== Summary ======"
  echo -e "Total playbooks: ${total_count}"
  echo -e "Passed: ${GREEN}${success_count}${NC}"
  
  if [ ${#failed_playbooks[@]} -eq 0 ]; then
    echo -e "${GREEN}All playbooks passed syntax check!${NC}"
    exit 0
  else
    echo -e "Failed: ${RED}${#failed_playbooks[@]}${NC}"
    echo -e "${RED}The following playbooks failed syntax check:${NC}"
    printf "  %s\n" "${failed_playbooks[@]}"
    exit 1
  fi
}

main "$@"
