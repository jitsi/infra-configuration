#!/usr/bin/env python3
import oci
import sys

import logging
logging.basicConfig()
logging.getLogger('oci').setLevel(logging.DEBUG)

# Initialize service client with instance principal
signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner(log_requests=True)
core_client = oci.core.VirtualNetworkClient(config={"log_requests": True}, signer=signer)

vnic_id = sys.argv[1]

# Send the request to service, some parameters are not required, see API
# doc for more info
get_vnic_response = core_client.get_vnic(vnic_id=vnic_id)

with open(sys.argv[2], 'w') as f:
  print(get_vnic_response.data, file=f)
