#!/bin/bash
set -e

# Script to try multiple AZs for spot capacity
REQUEST_ID="$1"
SECURITY_GROUP_ID="$2"
AMI_ID="$3"
EBS_VOLUME_ID="$4"
INSTANCE_TYPE="$5"
IAM_PROFILE="$6"
KEY_NAME="$7"
USER_DATA_B64="$8"
INITIAL_AZ="$9"
shift 9
ALLOWED_AZS=("$@")

echo "Initial spot request ID: $REQUEST_ID"
echo "Initial AZ: $INITIAL_AZ"
echo "Allowed AZs: ${ALLOWED_AZS[@]}"
echo "EBS Volume ID: $EBS_VOLUME_ID"

# Function to check spot request status
check_spot_request() {
  local request_id=$1
  local status=$(aws ec2 describe-spot-instance-requests \
    --spot-instance-request-ids $request_id \
    --query "SpotInstanceRequests[0].Status.Code" --output text 2>/dev/null || echo "error")
  echo $status
}

# Function to cancel a spot request
cancel_spot_request() {
  local request_id=$1
  if [ -n "$request_id" ]; then
    echo "Cancelling spot request $request_id"
    aws ec2 cancel-spot-instance-requests --spot-instance-request-ids $request_id || true
  fi
}

# Function to save state
save_state() {
  local request_id=$1
  local instance_id=$2
  local az=$3
  local state=$4
  
  echo "{\"instance_id\": \"$instance_id\", \"request_id\": \"$request_id\", \"az\": \"$az\", \"state\": \"$state\"}" > spot_instance_state.json
  echo "Saved state: instance=$instance_id, request=$request_id, az=$az, state=$state"
  cat spot_instance_state.json
}

# Function to try a specific AZ
try_az() {
  local az=$1
  local current_request_id=$2
  echo "Trying availability zone: $az"
  
  # Cancel existing request if needed
  if [ -n "$current_request_id" ]; then
    cancel_spot_request "$current_request_id"
  fi
  
  # If this is not the initial AZ, we need to move the EBS volume

  if [ "$az" != "$INITIAL_AZ" ]; then
    echo "Moving EBS volume $EBS_VOLUME_ID to $az"
    
    # Ensure the volume exists before proceeding
    if [ -z "$EBS_VOLUME_ID" ]; then
      echo "ERROR: No EBS volume ID found!"
      return 1
    fi

    # Create a snapshot of the existing volume

# Check the current state of the volume
volume_state=$(aws ec2 describe-volumes --volume-ids "$EBS_VOLUME_ID" --query "Volumes[0].State" --output text)

# If the volume is deleting, treat it as if it doesn't exist
if [ "$volume_state" == "deleting" ]; then
    echo "WARNING: Volume $EBS_VOLUME_ID is deleting. Treating as non-existent and creating a new volume."
    EBS_VOLUME_ID=""
fi

# If no valid volume exists, create a new one instead of failing
if [ -z "$EBS_VOLUME_ID" ]; then
    echo "No valid volume found, creating a new volume in AZ $az..."
    NEW_VOLUME_ID=$(aws ec2 create-volume --availability-zone "$az" --volume-type gp3 --size 100 --query "VolumeId" --output text)

    if [ -z "$NEW_VOLUME_ID" ]; then
        echo "ERROR: Failed to create a new volume in $az."
        exit 1
    fi

    echo "New volume created: $NEW_VOLUME_ID in $az"

    # Wait for the new volume to be available before proceeding
    echo "Waiting for new volume $NEW_VOLUME_ID to become available..."
    aws ec2 wait volume-available --volume-ids "$NEW_VOLUME_ID"

    EBS_VOLUME_ID="$NEW_VOLUME_ID"
else
    # Proceed with snapshotting and moving the existing volume

    if [ -z "$snapshot_id" ]; then
        echo "ERROR: Snapshot creation failed."
        exit 1
    fi

    # Wait for snapshot to complete
    echo "Waiting for snapshot $snapshot_id to complete..."
    aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id"

    # Create a new volume from the snapshot in the new AZ
    NEW_VOLUME_ID=$(aws ec2 create-volume --snapshot-id "$snapshot_id" --availability-zone "$az" --volume-type gp3 --query "VolumeId" --output text)

    if [ -z "$NEW_VOLUME_ID" ]; then
        echo "ERROR: Failed to create a new volume in $az."
        exit 1
    fi

    echo "New volume created: $NEW_VOLUME_ID in $az"
    EBS_VOLUME_ID="$NEW_VOLUME_ID"
fi
    snapshot_id=$(aws ec2 create-snapshot --volume-id $EBS_VOLUME_ID --description "Auto-move snapshot" --query SnapshotId --output text)
    echo "Snapshot created: $snapshot_id"

    # Ensure snapshot creation succeeded
    if [ -z "$snapshot_id" ] || [ "$snapshot_id" == "None" ]; then
      echo "ERROR: Failed to create a snapshot for volume $EBS_VOLUME_ID."
      exit 1
    fi

    # Wait for the snapshot to complete
    echo "Waiting for snapshot $snapshot_id to complete..."
      aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id" || {
        echo "ERROR: Snapshot creation failed."
        exit 1
    }

    echo "Snapshot is ready."

    # Create a new volume in the desired AZ
    NEW_VOLUME_ID=$(aws ec2 create-volume --snapshot-id $snapshot_id --availability-zone $az --volume-type gp3 --query VolumeId --output text)
    echo "New volume created: $NEW_VOLUME_ID in $az"

    # Wait for the new volume to be available
    aws ec2 wait volume-available --volume-ids $NEW_VOLUME_ID

    # Attach the new volume to the instance
    echo "Attaching new volume $NEW_VOLUME_ID to instance in AZ $az..."
    aws ec2 attach-volume --volume-id $NEW_VOLUME_ID --instance-id "$INSTANCE_ID" --device /dev/sdh

    # Optional: Detach and delete old volume after successful migration
    volume_state=$(aws ec2 describe-volumes --volume-ids "$EBS_VOLUME_ID" --query "Volumes[0].State" --output text)

    if [ "$volume_state" == "in-use" ]; then
      echo "Detaching volume $EBS_VOLUME_ID..."
      aws ec2 detach-volume --volume-id "$EBS_VOLUME_ID"
      aws ec2 wait volume-available --volume-ids "$EBS_VOLUME_ID"
    else
      echo "Volume $EBS_VOLUME_ID is already available, skipping detachment."
    fi

    # Update the EBS_VOLUME_ID variable for future use
    EBS_VOLUME_ID="$NEW_VOLUME_ID"
    echo "Volume successfully moved and attached in $az!"
  fi

  new_request=$(aws ec2 request-spot-instances --instance-count 1 --launch-specification "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"UserData\": \"$USER_DATA_B64\",
    \"Placement\": {\"AvailabilityZone\": \"$az\"}
  }")
 
  local new_request_id=$(echo $new_request | jq -r '.SpotInstanceRequests[0].SpotInstanceRequestId')
  echo "New request ID: $new_request_id"
  save_state "$new_request_id" "" "$az" "pending"
  
  # Wait for spot request status
  local MAX_ATTEMPTS=18
  local ATTEMPT=0
  
  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do

# Wait for the Spot request to be fulfilled before creating snapshots
local MAX_ATTEMPTS=18
local ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    local status=$(check_spot_request "$new_request_id")
    echo "Status: $status (attempt $ATTEMPT of $MAX_ATTEMPTS)"
    
    if [ "$status" = "fulfilled" ]; then
        # Get instance ID
        local instance_id=$(aws ec2 describe-spot-instance-requests           --spot-instance-request-ids "$new_request_id"           --query "SpotInstanceRequests[0].InstanceId" --output text)

        echo "Spot Request fulfilled with instance ID: $instance_id"
        save_state "$new_request_id" "$instance_id" "$az" "created"

        # Wait for instance to be running
        echo "Waiting for instance $instance_id to reach running state..."
        aws ec2 wait instance-running --instance-ids "$instance_id"

        # Now we know the instance is running - Create a snapshot only if migration is needed
        if [ "$az" != "$INITIAL_AZ" ]; then
            echo "Creating a snapshot for volume migration..."
            snapshot_id=$(aws ec2 create-snapshot --volume-id "$EBS_VOLUME_ID" --description "Auto-move snapshot" --query "SnapshotId" --output text)

            if [ -z "$snapshot_id" ]; then
                echo "ERROR: Snapshot creation failed."
                exit 1
            fi

            # Wait for snapshot to complete
            echo "Waiting for snapshot $snapshot_id to complete..."
            aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id"
        fi

        echo "Instance is now running and ready"
        save_state "$new_request_id" "$instance_id" "$az" "running"
        return 0
    fi
    
    ATTEMPT=$((ATTEMPT+1))
    sleep 10
done

echo "Spot request timed out"
save_state "$new_request_id" "" "$az" "timeout"
return 1
    local status=$(check_spot_request "$new_request_id")
    echo "Status: $status (attempt $ATTEMPT of $MAX_ATTEMPTS)"
    
    if [ "$status" = "fulfilled" ]; then
      # Get instance ID
      local instance_id=$(aws ec2 describe-spot-instance-requests \
        --spot-instance-request-ids $new_request_id \
        --query "SpotInstanceRequests[0].InstanceId" --output text)

      # Validate instance ID
      if [ -z "$instance_id" ] || [ "$instance_id" == "None" ]; then
        echo "ERROR: Failed to retrieve instance ID for Spot request $new_request_id"
        exit 1
      fi
      
      echo "Request fulfilled with instance ID: $instance_id"
      save_state "$new_request_id" "$instance_id" "$az" "created"
      
      # Wait for instance to be running
      echo "Waiting for instance $instance_id to reach running state..."
      aws ec2 wait instance-running --instance-ids $instance_id
      
      # Wait for status checks to pass
      echo "Waiting for instance status checks..."
      aws ec2 wait instance-status-ok --instance-ids $instance_id
      
      # Final state update
      echo "Instance is now running and ready"
      save_state "$new_request_id" "$instance_id" "$az" "running"
      return 0
    elif [ "$status" = "capacity-not-available" ] || [ "$status" = "capacity-oversubscribed" ] || [ "$status" = "error" ]; then
      echo "Spot request failed with status: $status"
      save_state "$new_request_id" "" "$az" "failed"
      return 1
    fi
    
    ATTEMPT=$((ATTEMPT+1))
    sleep 10
  done
  
  echo "Spot request timed out"
  save_state "$new_request_id" "" "$az" "timeout"
  return 1
}

# Process the initial spot request first
CURRENT_REQUEST_ID="$REQUEST_ID"
INITIAL_STATUS=$(check_spot_request "$CURRENT_REQUEST_ID")

if [ "$INITIAL_STATUS" = "fulfilled" ]; then
  # Check if already running
  INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --spot-instance-request-ids $CURRENT_REQUEST_ID \
    --query "SpotInstanceRequests[0].InstanceId" --output text)
  
  if [ -n "$INSTANCE_ID" ]; then
    INSTANCE_STATE=$(aws ec2 describe-instances \
      --instance-ids $INSTANCE_ID \
      --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "unknown")
    
    if [ "$INSTANCE_STATE" = "running" ]; then
      echo "Initial spot request already has a running instance: $INSTANCE_ID"
      save_state "$CURRENT_REQUEST_ID" "$INSTANCE_ID" "$INITIAL_AZ" "running"
      touch "$(dirname "$0")/.spot_provisioning_complete"
      exit 0
    fi
  fi
fi

# Try each AZ in order
for AZ in "${ALLOWED_AZS[@]}"; do
  echo "===== Trying AZ: $AZ ====="
  if try_az "$AZ" "$CURRENT_REQUEST_ID"; then
    echo "Success in $AZ"
    touch "$(dirname "$0")/.spot_provisioning_complete"
    exit 0
  fi
  
  echo "Failed in $AZ, trying next zone"
  CURRENT_REQUEST_ID=$(grep -o '"request_id": "[^"]*' spot_instance_state.json | cut -d'"' -f4)
done

echo "Failed to find capacity in any availability zone"
save_state "$CURRENT_REQUEST_ID" "" "${ALLOWED_AZS[0]}" "all_az_failed"
touch "$(dirname "$0")/.spot_provisioning_complete"
exit 1