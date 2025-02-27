#!/bin/bash
# update_spot_instance_state.sh
# Script to properly update and validate spot instance state

set -e

# Function to check spot request status
check_spot_request() {
  local request_id=$1
  local status=$(aws ec2 describe-spot-instance-requests \
    --spot-instance-request-ids $request_id \
    --query "SpotInstanceRequests[0].Status.Code" --output text 2>/dev/null || echo "error")
  echo $status
}

# Function to check if an instance is running
check_instance_state() {
  local instance_id=$1
  local state=$(aws ec2 describe-instances \
    --instance-ids $instance_id \
    --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "unknown")
  echo $state
}

verify_instance() {
  local instance_id=$1
  local state=$(aws ec2 describe-instances --instance-ids $instance_id --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "terminated")
  
  if [ "$state" = "terminated" ] || [ "$state" = "shutting-down" ] || [ "$state" = "not-found" ]; then
    echo "false"
  else
    echo "true"
  fi
}


# Function to save state
save_state() {
  local request_id=$1
  local instance_id=$2
  local az=$3
  local state=$4
  
  # Verify the instance is not terminated before saving a "running" state
  if [ "$state" = "running" ] && [ -n "$instance_id" ]; then
    local is_valid=$(verify_instance "$instance_id")
    if [ "$is_valid" = "false" ]; then
      echo "Warning: Instance $instance_id appears to be terminated or not found. Not saving running state."
      state="terminated"
      instance_id=""
    fi
  fi
  
  echo "{\"instance_id\": \"$instance_id\", \"request_id\": \"$request_id\", \"az\": \"$az\", \"state\": \"$state\"}" > spot_instance_state.json
  echo "Saved state: instance=$instance_id, request=$request_id, az=$az, state=$state"
  
  # Output JSON for better visibility
  cat spot_instance_state.json
}

# Main logic
REQUEST_ID=$1
AZ=$2

if [ -z "$REQUEST_ID" ] || [ -z "$AZ" ]; then
  echo "Error: Missing required parameters."
  echo "Usage: $0 <request_id> <availability_zone>"
  # Create the marker file even on failure
  touch "$(dirname "$0")/.spot_provisioning_complete"
  exit 1
fi

# Initial save of pending state
save_state "$REQUEST_ID" "" "$AZ" "pending"

# Wait for the spot request to be fulfilled
echo "Waiting for spot request $REQUEST_ID to be fulfilled..."
FULFILLED=false
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  STATUS=$(check_spot_request "$REQUEST_ID")
  echo "Current status: $STATUS (attempt $ATTEMPT of $MAX_ATTEMPTS)"
  
  if [ "$STATUS" = "fulfilled" ]; then
    FULFILLED=true
    break
  elif [ "$STATUS" = "capacity-not-available" ] || [ "$STATUS" = "capacity-oversubscribed" ] || [ "$STATUS" = "error" ]; then
    echo "Spot request failed with status: $STATUS"
    save_state "$REQUEST_ID" "" "$AZ" "failed"
    # Create the marker file even on failure
    touch "$(dirname "$0")/.spot_provisioning_complete"
    exit 1
  fi
  
  ATTEMPT=$((ATTEMPT+1))
  sleep 10
done

if [ "$FULFILLED" = false ]; then
  echo "Spot request not fulfilled after $MAX_ATTEMPTS attempts"
  save_state "$REQUEST_ID" "" "$AZ" "timeout"
  # Create the marker file even on failure
  touch "$(dirname "$0")/.spot_provisioning_complete"
  exit 1
fi

# Get the instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
  --spot-instance-request-ids $REQUEST_ID \
  --query "SpotInstanceRequests[0].InstanceId" --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ] || [ "$INSTANCE_ID" = "null" ]; then
  echo "Failed to get instance ID for fulfilled spot request"
  save_state "$REQUEST_ID" "" "$AZ" "error"
  # Create the marker file even on failure
  touch "$(dirname "$0")/.spot_provisioning_complete"
  exit 1
fi

echo "Spot request fulfilled with instance ID: $INSTANCE_ID"
save_state "$REQUEST_ID" "$INSTANCE_ID" "$AZ" "created"

# Wait for the instance to be running
echo "Waiting for instance $INSTANCE_ID to be running..."
RUNNING=false
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  STATE=$(check_instance_state "$INSTANCE_ID")
  echo "Current instance state: $STATE (attempt $ATTEMPT of $MAX_ATTEMPTS)"
  
  if [ "$STATE" = "running" ]; then
    RUNNING=true
    break
  elif [ "$STATE" = "terminated" ] || [ "$STATE" = "shutting-down" ]; then
    echo "Instance terminated or shutting down"
    save_state "$REQUEST_ID" "$INSTANCE_ID" "$AZ" "terminated"
    # Create the marker file even on failure
    touch "$(dirname "$0")/.spot_provisioning_complete"
    exit 1
  fi
  
  ATTEMPT=$((ATTEMPT+1))
  sleep 10
done

if [ "$RUNNING" = false ]; then
  echo "Instance not running after $MAX_ATTEMPTS attempts"
  save_state "$REQUEST_ID" "$INSTANCE_ID" "$AZ" "not_running"
  # Create the marker file even on failure
  touch "$(dirname "$0")/.spot_provisioning_complete"
  exit 1
fi

# Wait for instance status checks to pass
echo "Waiting for instance status checks to pass..."
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID || true

# Final state update
echo "Instance is now running and ready"
save_state "$REQUEST_ID" "$INSTANCE_ID" "$AZ" "running"

# Create an explicit marker file when done
touch "$(dirname "$0")/.spot_provisioning_complete"

echo "Success! Spot instance is ready for use"
exit 0












