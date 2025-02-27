#!/bin/bash
# Script to clean up lingering spot instances from broken Terraform deployments
# Usage: ./cleanup-spot-instances.sh [optional: tag-name-value]

set -e  # Exit on error
set -x  # Debug mode

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}= Spot Instance & Resource Cleanup Tool =${NC}"
echo -e "${GREEN}==========================================${NC}"

# Define tag filter if passed as argument
TAG_FILTER=""
if [ -n "$1" ]; then
  TAG_FILTER="Name=tag:Name,Values=$1"
  FILTER_ARG=(--filters "$TAG_FILTER")
else
  FILTER_ARG=()
fi

echo "Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
  echo -e "${RED}Error: AWS credentials not configured or invalid${NC}"
  exit 1
fi
echo "AWS credentials are valid"

# Fetch spot instance requests
SPOT_REQUESTS_JSON=$(aws ec2 describe-spot-instance-requests "${FILTER_ARG[@]}" --query 'SpotInstanceRequests[*].{ID:SpotInstanceRequestId,State:State,InstanceId:InstanceId}' --output json 2>/dev/null)

echo "Retrieved Spot Request JSON: $SPOT_REQUESTS_JSON"

# Ensure the response is valid JSON
if ! echo "$SPOT_REQUESTS_JSON" | jq empty 2>/dev/null; then
  echo -e "${RED}Error: Invalid JSON response from AWS CLI. Check AWS permissions or input parameters.${NC}"
  exit 1
fi

SPOT_REQUEST_COUNT=$(echo "$SPOT_REQUESTS_JSON" | jq 'length')
if ! [[ "$SPOT_REQUEST_COUNT" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}Error: Unexpected response format when counting spot instances.${NC}"
  exit 1
fi
echo -e "\nFound $SPOT_REQUEST_COUNT spot instance requests:"

echo "$SPOT_REQUESTS_JSON" | jq -r '.[] | "- ID: " + .ID + " | State: " + .State + " | Instance ID: " + (.InstanceId // "N/A")' || echo "No spot instances found."

# Extract instance and request IDs
request_ids=($(echo "$SPOT_REQUESTS_JSON" | jq -r 'map(select(.ID != null)) | .[].ID'))
instance_ids=($(echo "$SPOT_REQUESTS_JSON" | jq -r 'map(select(.InstanceId != null)) | .[].InstanceId'))

echo "Extracted Request IDs: ${request_ids[@]}"
echo "Extracted Instance IDs: ${instance_ids[@]}"

# Check if any spot requests exist
if [ "$SPOT_REQUEST_COUNT" -eq 0 ]; then
  echo -e "${GREEN}No spot instances to clean up.${NC}"
  exit 0
fi

# Ask for confirmation
echo -e "\n${YELLOW}WARNING: This will cancel spot requests, terminate instances, and clean up associated resources.${NC}"
read -p "Do you want to proceed? (y/n): " confirm

if [ "$confirm" != "y" ]; then
  echo -e "${YELLOW}Operation cancelled${NC}"
  exit 0
fi

# Function to detach but NOT delete the EBS volume attached to /data
detach_protected_volume() {
  for instance_id in "${instance_ids[@]}"; do
    volume_id=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[*].Instances[*].BlockDeviceMappings[?DeviceName==`/dev/sdf`].Ebs.VolumeId' --output text)
    if [ -n "$volume_id" ]; then
      echo "Detaching protected EBS volume $volume_id (mounted to /data) from instance $instance_id"
      aws ec2 detach-volume --volume-id "$volume_id"
    fi
  done
}

# Function to cancel spot requests
cancel_spot_requests() {
  if [ "${#request_ids[@]}" -gt 0 ]; then
    echo "Cancelling spot instance requests..."
    aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "${request_ids[@]}"
  fi
}

# Function to terminate instances
terminate_instances() {
  if [ "${#instance_ids[@]}" -gt 0 ]; then
    echo "Terminating instances..."
    aws ec2 terminate-instances --instance-ids "${instance_ids[@]}"
  fi
}

# Function to disassociate Elastic IPs
disassociate_eips() {
  for instance_id in "${instance_ids[@]}"; do
    EIP=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$instance_id" --query 'Addresses[*].PublicIp' --output text)
    if [ -n "$EIP" ]; then
      echo "Disassociating Elastic IP $EIP from instance $instance_id"
      aws ec2 disassociate-address --public-ip "$EIP"
    fi
  done
}

# Function to wait for termination
wait_for_termination() {
  if [ "${#instance_ids[@]}" -gt 0 ]; then
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids "${instance_ids[@]}"
  fi
}

# Execute cleanup functions
disassociate_eips
detach_protected_volume  # Ensure /data volume is detached but not deleted
cancel_spot_requests
terminate_instances
wait_for_termination

echo -e "\n${GREEN}Cleanup completed successfully!${NC}"
echo -e "${YELLOW}You may now proceed with a fresh Terraform deployment.${NC}"

exit 0
