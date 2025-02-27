#!/bin/sh
set -e

# Install required packages
echo "Installing required packages..."
apk add --no-cache docker curl aws-cli jq

# Verify Docker socket access
if [ ! -S /var/run/docker.sock ]; then
  echo "ERROR: Docker socket not accessible!"
  exit 1
fi

# Get instance metadata
echo "Retrieving instance metadata..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
SNS_TOPIC_ARN=${SNS_TOPIC_ARN:-""}

echo "Starting activity monitor for instance $INSTANCE_ID"
echo "Inactivity timeout set to $INACTIVITY_TIMEOUT seconds"

# Initial timestamp
last_activity=$(date +%s)

# Activity monitoring loop
while true; do
  CURRENT_TIME=$(date +%s)
  
  # Check for API activity in Ollama logs
  if docker exec ollama grep -q "POST /api" /var/log/ollama.log 2>/dev/null; then
    echo "Detected API activity in Ollama logs"
    last_activity=$CURRENT_TIME
    # Truncate the log after checking to avoid growing too large
    docker exec ollama truncate -s 0 /var/log/ollama.log 2>/dev/null || true
  fi
  
  # Check for HTTP activity in Open-WebUI
  if docker logs --since 1m open-webui 2>&1 | grep -q "GET /" || docker logs --since 1m open-webui 2>&1 | grep -q "POST /"; then
    echo "Detected HTTP activity in Open-WebUI"
    last_activity=$CURRENT_TIME
  fi
  
  # Check for recent connections to nginx
  if docker logs --since 1m nginx 2>&1 | grep -q '"GET /'; then
    echo "Detected web activity in nginx logs"
    last_activity=$CURRENT_TIME
  fi
  
  # Calculate inactivity time
  inactive_time=$((CURRENT_TIME - last_activity))
  
  # Periodically log status for debugging
  if [ $((CURRENT_TIME % 300)) -lt 10 ]; then
    echo "Activity monitor: Instance has been inactive for $inactive_time seconds (timeout: $INACTIVITY_TIMEOUT)"
  fi
  
  # Check if we've exceeded the inactivity timeout
  if [ $inactive_time -gt $INACTIVITY_TIMEOUT ]; then
    echo "Instance has been inactive for $inactive_time seconds, shutting down..."
    
    # Send notification if SNS Topic is configured
    if [ -n "$SNS_TOPIC_ARN" ]; then
      aws sns publish \
        --region $REGION \
        --topic-arn "$SNS_TOPIC_ARN" \
        --message "Ollama instance $INSTANCE_ID is shutting down due to inactivity (${inactive_time}s)." \
        --subject "Ollama Instance Auto-Shutdown" || true
    fi
    
    # Stop the instance using EC2 API
    echo "Calling EC2 API to stop the instance..."
    aws ec2 stop-instances --region $REGION --instance-ids $INSTANCE_ID
    
    echo "Shutdown command sent, exiting monitor..."
    exit 0
  fi
  
  # Sleep before checking again
  sleep 60
done