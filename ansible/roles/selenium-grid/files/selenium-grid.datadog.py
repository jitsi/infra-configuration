

import time
import requests

from checks import AgentCheck
import json

class SeleniumGridCheck(AgentCheck):
    def check(self, instance):

        # Load values from the instance config
        default_url = self.init_config.get('default_url', 'http://localhost:5555/wd/hub/sessions')
        url = instance.get('url',default_url)

        default_timeout = self.init_config.get('default_timeout', 10)
        timeout = float(instance.get('timeout', default_timeout))

        default_slots = self.init_config.get('default_slots', 1)
        slots = int(instance.get('slots', default_slots))

        # Check the URL
        start_time = time.time()
        try:
            r = requests.get(url, timeout=timeout)
            sessions = r.json()
            session_count = len(sessions['value'])

            end_time = time.time()
        except requests.Timeout as e:
            # If there's a timeout
#            self.timeout_event(url, timeout, aggregation_key)
            return

        timing = end_time - start_time
        self.gauge('grid.session_count', session_count)
        self.gauge('grid.session_slots', slots)


if __name__ == '__main__':
    check, instances = SeleniumGridCheck.from_yaml('/etc/dd-agent/conf.d/selenium_grid.yaml')
    for instance in instances:
        print("\nRunning the check against url: %s" % (instance['url']))
        check.check(instance)
        if check.has_events():
            print('Events: %s' % (check.get_events()))
        print('Metrics: %s' % (check.get_metrics()))