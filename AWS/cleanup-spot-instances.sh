#!/bin/bash
# Script to clean up lingering spot instances from broken Terraform deployments
# Usage: ./cleanup-spot-instances.sh [optional: tag-name-value]

set -e  # Exit on error

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
  echo -e "${YELLOW}Filtering by tag:Name=$1${NC}"
else
  echo -e "${YELLOW}No tag filter specified, will show all spot instances${NC}"
fi

# Check AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo -e "${RED}Error: AWS CLI is not installed.${NC}"
  exit 1
fi

# Check AWS credentials
echo -e "\n${GREEN}Checking AWS credentials...${NC}"
if ! aws sts get-caller-identity &> /dev/null; then
  echo -e "${RED}Error: AWS credentials not configured or invalid.${NC}"
  exit 1
fi
echo -e "${GREEN}AWS credentials are valid${NC}"

# Function to get current spot instance requests
get_spot_requests() {
  echo -e "\n${GREEN}Fetching active spot instance requests...${NC}"
  
  local spot_requests
  if [ -n "$TAG_FILTER" ]; then
    spot_requests=$(aws ec2 describe-spot-instance-requests --filters "$TAG_FILTER" "Name=state,Values=open,active,closed" --output json)
  else
    spot_requests=$(aws ec2 describe-spot-instance-requests --filters "Name=state,Values=open,active,closed" --output json)
  fi
  
  echo "$spot_requests"
}

# Function to get a list of instance IDs from spot requests
get_spot_instance_ids() {
  local requests="$1"
  local instance_ids=$(echo "$requests" | jq -r '.SpotInstanceRequests[] | select(.InstanceId != null) | .InstanceId')
  echo "$instance_ids"
}

# Function to get a list of spot request IDs
get_spot_request_ids() {
  local requests="$1"
  local request_ids=$(echo "$requests" | jq -r '.SpotInstanceRequests[].SpotInstanceRequestId')
  echo "$request_ids"
}

# Function to cancel spot instance requests
cancel_spot_requests() {
  local request_ids=("$@")
  if [ ${#request_ids[@]} -eq 0 ]; then
    echo -e "${YELLOW}No spot requests to cancel${NC}"
    return
  fi
  
  echo -e "\n${GREEN}Cancelling spot instance requests...${NC}"
  for request_id in "${request_ids[@]}"; do
    echo -e "${YELLOW}Cancelling request: $request_id${NC}"
    aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "$request_id"
  done
  echo -e "${GREEN}All spot requests cancelled${NC}"
}

# Function to terminate EC2 instances
terminate_instances() {
  local instance_ids=("$@")
  if [ ${#instance_ids[@]} -eq 0 ]; then
    echo -e "${YELLOW}No instances to terminate${NC}"
    return
  fi
  
  echo -e "\n${GREEN}Terminating instances...${NC}"
  for instance_id in "${instance_ids[@]}"; do
    echo -e "${YELLOW}Terminating instance: $instance_id${NC}"
    aws ec2 terminate-instances --instance-ids "$instance_id"
  done
  echo -e "${GREEN}All instances termination initiated${NC}"
}

# Function to find volume attachments for an instance
find_volume_attachments() {
  local instance_id="$1"
  local volumes=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$instance_id" --query "Volumes[*].{ID:VolumeId,Size:Size,Type:VolumeType,AZ:AvailabilityZone,State:State}" --output json)
  echo "$volumes"
}

# Function to list EIPs associated with an instance
find_eip_associations() {
  local instance_id="$1"
  local eips=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$instance_id" --query "Addresses[*].{AllocationId:AllocationId,PublicIp:PublicIp}" --output json)
  echo "$eips"
}

# Function to disassociate EIPs
disassociate_eips() {
  local instance_id="$1"
  local eips=$(find_eip_associations "$instance_id")
  local allocation_ids=$(echo "$eips" | jq -r '.[].AllocationId')
  
  if [ -z "$allocation_ids" ] || [ "$allocation_ids" == "null" ]; then
    echo -e "${YELLOW}No EIPs to disassociate for instance $instance_id${NC}"
    return
  fi
  
  echo -e "${GREEN}Disassociating EIPs from instance $instance_id...${NC}"
  for allocation_id in $allocation_ids; do
    echo -e "${YELLOW}Disassociating EIP: $allocation_id${NC}"
    aws ec2 disassociate-address --association-id "$allocation_id"
  done
}

# Function to check Terraform state for resources
check_terraform_state() {
  if [ ! -f "terraform.tfstate" ]; then
    echo -e "${YELLOW}No terraform.tfstate file found in current directory${NC}"
    return
  fi
  
  echo -e "\n${GREEN}Checking Terraform state for spot instances...${NC}"
  local tf_spot_instances=$(jq -r '.resources[] | select(.type == "aws_spot_instance_request") | .instances[].attributes.id' terraform.tfstate 2>/dev/null || echo "")
  
  if [ -n "$tf_spot_instances" ]; then
    echo -e "${YELLOW}Found spot instance requests in Terraform state:${NC}"
    echo "$tf_spot_instances"
  else
    echo -e "${YELLOW}No spot instance requests found in Terraform state${NC}"
  fi
}

# Function to wait for instance termination
wait_for_termination() {
  local instance_ids=("$@")
  if [ ${#instance_ids[@]} -eq 0 ]; then
    return
  fi
  
  echo -e "\n${GREEN}Waiting for instances to terminate...${NC}"
  for instance_id in "${instance_ids[@]}"; do
    echo -e "${YELLOW}Waiting for termination of: $instance_id${NC}"
    aws ec2 wait instance-terminated --instance-ids "$instance_id"
    echo -e "${GREEN}Instance $instance_id terminated${NC}"
  done
}

# Function to update the spot_instance_state.json file
update_state_file() {
  if [ ! -f "spot_instance_state.json" ]; then
    echo -e "${YELLOW}No spot_instance_state.json file found${NC}"
    return
  fi
  
  echo -e "\n${GREEN}Updating spot_instance_state.json...${NC}"
  echo '{
  "instance_id": "",
  "request_id": "",
  "az": "",
  "state": "cleaned"
}' > spot_instance_state.json
  echo -e "${GREEN}spot_instance_state.json updated${NC}"
}

# Function to find orphaned volumes (unattached)
find_orphaned_volumes() {
  echo -e "\n${GREEN}Looking for orphaned volumes...${NC}"
  local orphaned_volumes=$(aws ec2 describe-volumes --filters "Name=status,Values=available" --query 'Volumes[?Tags[?Key==`Name` && Value==`ollama-data`]].{ID:VolumeId,Size:Size,Type:VolumeType,AZ:AvailabilityZone,CreatedTime:CreateTime}' --output json)
  
  if [ -z "$orphaned_volumes" ] || [ "$orphaned_volumes" == "[]" ]; then
    echo -e "${YELLOW}No orphaned volumes found${NC}"
    return
  fi
  
  echo -e "${YELLOW}Found orphaned volumes:${NC}"
  echo "$orphaned_volumes" | jq '.'
  
  read -p "Do you want to delete these volumes? (y/n): " delete_volumes
  if [ "$delete_volumes" == "y" ]; then
    local volume_ids=$(echo "$orphaned_volumes" | jq -r '.[].ID')
    for volume_id in $volume_ids; do
      echo -e "${YELLOW}Deleting volume: $volume_id${NC}"
      aws ec2 delete-volume --volume-id "$volume_id"
    done
    echo -e "${GREEN}All orphaned volumes deleted${NC}"
  else
    echo -e "${YELLOW}Skipping volume deletion${NC}"
  fi
}

# Main execution
spot_requests=$(get_spot_requests)
request_count=$(echo "$spot_requests" | jq '.SpotInstanceRequests | length')

if [ "$request_count" -eq 0 ]; then
  echo -e "${GREEN}No active spot instance requests found${NC}"
  check_terraform_state
  find_orphaned_volumes
  exit 0
fi

echo -e "\n${GREEN}Found $request_count spot instance requests:${NC}"
echo "$spot_requests" | jq '.SpotInstanceRequests[] | {RequestId: .SpotInstanceRequestId, State: .State, InstanceId: .InstanceId, CreateTime: .CreateTime}'

instance_ids=($(get_spot_instance_ids "$spot_requests"))
request_ids=($(get_spot_request_ids "$spot_requests"))

# Display attached resources for each instance
if [ ${#instance_ids[@]} -gt 0 ]; then
  echo -e "\n${GREEN}Checking resources attached to instances:${NC}"
  for instance_id in "${instance_ids[@]}"; do
    echo -e "\n${YELLOW}Resources for instance: $instance_id${NC}"
    
    # Get basic instance details
    instance_details=$(aws ec2 describe-instances --instance-ids "$instance_id" --query "Reservations[0].Instances[0].{State:State.Name,InstanceType:InstanceType,LaunchTime:LaunchTime}" --output json 2>/dev/null || echo "{}")
    echo -e "${GREEN}Instance details:${NC}"
    echo "$instance_details" | jq '.'
    
    # Get volumes
    volumes=$(find_volume_attachments "$instance_id")
    if [ "$volumes" != "[]" ]; then
      echo -e "\n${GREEN}Attached volumes:${NC}"
      echo "$volumes" | jq '.'
    else
      echo -e "\n${GREEN}No volumes attached${NC}"
    fi
    
    # Get EIPs
    eips=$(find_eip_associations "$instance_id")
    if [ "$eips" != "[]" ]; then
      echo -e "\n${GREEN}Associated EIPs:${NC}"
      echo "$eips" | jq '.'
    else
      echo -e "\n${GREEN}No EIPs associated${NC}"
    fi
  done
fi

# Ask for confirmation
echo -e "\n${YELLOW}WARNING: This will cancel spot requests, terminate instances, and clean up associated resources${NC}"
read -p "Do you want to proceed? (y/n): " confirm

if [ "$confirm" != "y" ]; then
  echo -e "${YELLOW}Operation cancelled${NC}"
  exit 0
fi

# First disassociate any EIPs
for instance_id in "${instance_ids[@]}"; do
  disassociate_eips "$instance_id"
done

# Cancel spot requests
cancel_spot_requests "${request_ids[@]}"

# Terminate instances
terminate_instances "${instance_ids[@]}"

# Wait for termination to complete
wait_for_termination "${instance_ids[@]}"

# Update state file
update_state_file

# Check for orphaned volumes
find_orphaned_volumes

# Successfully completed
echo -e "\n${GREEN}Cleanup completed successfully!${NC}"
echo -e "${YELLOW}You may now proceed with a fresh Terraform deployment${NC}"

exit 0