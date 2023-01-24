#!/bin/bash
export TORTURE_EXCLUDE_TESTS="{{ jitsi_torture_exclude_tests }}"

cd {{ jitsi_torture_path }}

{% if torture_longtest_only == 'long' %}
./test-runner-long.sh {{ jitsi_torture_domain }} {{ torture_longtest_duration }}
{% elif torture_longtest_only == 'all' %}
./test-runner-all.sh {{ jitsi_torture_domain }}
{% else %}
./test-runner.sh {{ jitsi_torture_domain }}
{% endif %}