#!/bin/bash

# Fetch the most recent active Spot Instance Request
spot_request_id=$(aws ec2 describe-spot-instance-requests \
  --filters Name=state,Values=active \
  --query "SpotInstanceRequests[0].SpotInstanceRequestId" \
  --output text)

# Fetch the instance ID associated with the Spot Request
instance_id=$(aws ec2 describe-spot-instance-requests \
  --spot-instance-request-ids "$spot_request_id" \
  --query "SpotInstanceRequests[0].InstanceId" \
  --output text)

# Return the values as JSON for Terraform
echo "{\"spot_request_id\": \"$spot_request_id\", \"instance_id\": \"$instance_id\"}"
