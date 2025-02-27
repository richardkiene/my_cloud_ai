#!/bin/bash
set -e

# All configuration is passed via environment variables:
# CUSTOM_DOMAIN
# ADMIN_EMAIL
# WEBUI_PASSWORD
# API_GATEWAY_STATUS_URL
# API_GATEWAY_START_URL
# VOLUME_ID
# SNS_TOPIC_ARN
# SSM_PARAM_URL

# Set up logging
echo "Starting Ollama setup with the following configuration:"
echo "  Domain: $CUSTOM_DOMAIN"
echo "  Admin Email: $ADMIN_EMAIL"
echo "  Volume ID: $VOLUME_ID"
echo "  SSM Parameter: $SSM_PARAM_URL"

# Get API Gateway URLs from SSM Parameter Store or EC2 instance tags
get_api_urls() {
    # First try to get from SSM Parameter
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    
    echo "Retrieving API Gateway URLs..."
    
    # Try to get from SSM Parameter Store first
    if [ -n "$SSM_PARAM_URL" ]; then
        echo "Getting API Gateway URL from SSM Parameter: $SSM_PARAM_URL"
        API_BASE_URL=$(aws ssm get-parameter --name "$SSM_PARAM_URL" --region "$REGION" --query "Parameter.Value" --output text 2>/dev/null)
        
        if [ -n "$API_BASE_URL" ] && [ "$API_BASE_URL" != "WILL_BE_UPDATED_LATER" ]; then
            echo "Found API Gateway URL in SSM: $API_BASE_URL"
            API_GATEWAY_STATUS_URL="${API_BASE_URL}/status"
            API_GATEWAY_START_URL="${API_BASE_URL}/start"
            return 0
        fi
    fi
    
    # If not found in SSM, try to get from instance tags
    echo "Getting API Gateway URLs from instance tags..."
    API_BASE_URL=$(aws ec2 describe-tags --region "$REGION" --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=ApiGatewayUrl" --query "Tags[0].Value" --output text 2>/dev/null)
    
    if [ -n "$API_BASE_URL" ] && [ "$API_BASE_URL" != "https://PLACEHOLDER_API_GATEWAY" ]; then
        echo "Found API Gateway URL in instance tags: $API_BASE_URL"
        API_GATEWAY_STATUS_URL="${API_BASE_URL}/status"
        API_GATEWAY_START_URL="${API_BASE_URL}/start"
        return 0
    fi
    
    # If we get here, use the placeholder URLs provided by Terraform
    echo "Using placeholder API Gateway URLs. These will be updated dynamically in the HTML."
    return 0
}

# Create necessary directories
mkdir -p /data /data/ollama/models /data/open-webui /data/nginx/conf /data/certbot/conf /data/certbot/www /data/scripts

# Find and attach the EBS volume
attach_data_volume() {
    echo "Attaching data volume ${VOLUME_ID}..."
    
    # Detect instance region and ID
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
    
    # Check if volume is already attached
    ATTACHED_INSTANCE=$(aws ec2 describe-volumes --region $REGION --volume-ids $VOLUME_ID --query 'Volumes[0].Attachments[0].InstanceId' --output text)
    
    if [ "$ATTACHED_INSTANCE" == "$INSTANCE_ID" ]; then
        echo "Volume is already attached to this instance."
    elif [ "$ATTACHED_INSTANCE" != "None" ] && [ -n "$ATTACHED_INSTANCE" ]; then
        echo "Volume is attached to another instance ($ATTACHED_INSTANCE). Detaching..."
        aws ec2 detach-volume --region $REGION --volume-id $VOLUME_ID
        
        # Wait for detachment
        echo "Waiting for volume to detach..."
        aws ec2 wait volume-available --region $REGION --volume-ids $VOLUME_ID
    fi
    
    # Check if volume is in the same AZ as the instance
    VOLUME_AZ=$(aws ec2 describe-volumes --region $REGION --volume-ids $VOLUME_ID --query 'Volumes[0].AvailabilityZone' --output text)
    
    if [ "$VOLUME_AZ" != "$AZ" ]; then
        echo "Volume is in $VOLUME_AZ but instance is in $AZ. Creating a snapshot and new volume..."
        
        # Create a snapshot
        SNAPSHOT_ID=$(aws ec2 create-snapshot --region $REGION --volume-id $VOLUME_ID --description "Moving volume to $AZ" --query 'SnapshotId' --output text)
        
        # Wait for snapshot to complete
        echo "Waiting for snapshot to complete..."
        aws ec2 wait snapshot-completed --region $REGION --snapshot-ids $SNAPSHOT_ID
        
        # Create a new volume in the instance's AZ
        NEW_VOLUME_ID=$(aws ec2 create-volume --region $REGION --availability-zone $AZ --snapshot-id $SNAPSHOT_ID --volume-type gp3 --query 'VolumeId' --output text)
        
        # Wait for volume to be available
        echo "Waiting for new volume to be available..."
        aws ec2 wait volume-available --region $REGION --volume-ids $NEW_VOLUME_ID
        
        # Update the VOLUME_ID for attachment
        echo "Using new volume $NEW_VOLUME_ID in $AZ instead of original volume $VOLUME_ID in $VOLUME_AZ"
        VOLUME_ID=$NEW_VOLUME_ID
    fi
    
    # Attach the volume
    echo "Attaching volume $VOLUME_ID to instance $INSTANCE_ID at device /dev/sdh..."
    aws ec2 attach-volume --region $REGION --volume-id $VOLUME_ID --instance-id $INSTANCE_ID --device /dev/sdh
    
    # Wait for attachment
    echo "Waiting for volume attachment to complete..."
    while ! aws ec2 describe-volumes --region $REGION --volume-ids $VOLUME_ID --query 'Volumes[0].Attachments[0].State' --output text | grep -q "attached"; do
        sleep 5
    done
    
    # Find the actual device path (especially for NVMe)
    sleep 10  # Give the system time to create the device file
    DEVICE="/dev/sdh"
    
    # Handle NVMe devices (common on newer instance types like G5)
    if [ ! -e $DEVICE ]; then
        echo "Device $DEVICE not found, checking for NVMe devices..."
        for nvme in /dev/nvme*n1; do
            if [ -e "$nvme" ]; then
                DEVICE=$nvme
                echo "Using NVMe device: $DEVICE"
                break
            fi
        done
    fi
    
    # If device not found, try to use the EBS device by volume ID
    if [ ! -e $DEVICE ]; then
        echo "Still no device found, trying to find by EBS volume ID..."
        for dev in $(find /dev -name "nvme*n1"); do
            if [ -e "$dev" ]; then
                vol_id=$(nvme id-ctrl -v $dev | grep -i "vol" | awk '{print $NF}')
                if [[ "$vol_id" == *"$VOLUME_ID"* ]]; then
                    DEVICE=$dev
                    echo "Found device $DEVICE for volume $VOLUME_ID"
                    break
                fi
            fi
        done
    fi
    
    if [ ! -e $DEVICE ]; then
        echo "ERROR: Could not find the attached volume device!"
        aws sns publish --region $REGION --topic-arn $SNS_TOPIC_ARN --subject "Ollama Volume Error" --message "Could not find the attached volume device on instance $INSTANCE_ID"
        return 1
    fi
    
    # Check if the volume has a filesystem
    if ! file -s $DEVICE | grep -q "filesystem"; then
        echo "Creating new ext4 filesystem on $DEVICE..."
        mkfs.ext4 $DEVICE
    fi
    
    # Mount the volume
    echo "Mounting volume to /data..."
    mount $DEVICE /data
    
    # Add to fstab for persistence
    echo "$DEVICE /data ext4 defaults,nofail 0 2" >> /etc/fstab
    
    # Create necessary directories on mounted volume
    mkdir -p /data/ollama/models /data/open-webui /data/nginx/conf /data/certbot/conf /data/certbot/www /data/scripts
    
    # Ensure proper ownership and permissions
    chown -R 1000:1000 /data
    chmod -R 755 /data
    
    echo "Volume successfully attached and mounted at /data"
    return 0
}

setup_docker() {
    echo "Setting up Docker for NVIDIA GPU support..."
    
    # Verify NVIDIA drivers are working
    if ! nvidia-smi > /dev/null; then
        echo "ERROR: NVIDIA drivers not working properly!"
        return 1
    fi
    
    # Set up Docker daemon config
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "data-root": "/data/docker",
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "storage-driver": "overlay2"
}
EOF
    
    # Restart Docker to apply changes
    systemctl restart docker
    
    echo "Docker configured for GPU support."
    return 0
}

create_monitor_script() {
    echo "Creating activity monitoring script..."
    
    cat > /data/scripts/monitor-activity.sh << 'EOF'
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
EOF
    
    chmod +x /data/scripts/monitor-activity.sh
    echo "Activity monitoring script created successfully."
}

create_docker_compose() {
    echo "Creating docker-compose.yml..."
    
    cat > /data/docker-compose.yml << EOF
version: '3'
services:
  nginx:
    image: nginx:alpine
    container_name: nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /data/nginx/conf:/etc/nginx/conf.d
      - /data/certbot/conf:/etc/letsencrypt
      - /data/certbot/www:/var/www/certbot
    depends_on:
      - open-webui
    restart: unless-stopped
    command: "/bin/sh -c 'while :; do sleep 6h & wait \${!}; nginx -s reload; done & nginx -g \"daemon off;\"'"
  certbot:
    image: certbot/certbot
    container_name: certbot
    volumes:
      - /data/certbot/conf:/etc/letsencrypt
      - /data/certbot/www:/var/www/certbot
    restart: unless-stopped
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait \${!}; done;'"
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    ports:
      - "11434:11434"
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
    volumes:
      - /data/ollama/models:/root/.ollama
    restart: unless-stopped
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_AUTH=true
      - WEBUI_AUTH_USER=admin
      - WEBUI_AUTH_PASSWORD=${WEBUI_PASSWORD}
    volumes:
      - /data/open-webui:/root/.cache
    depends_on:
      - ollama
    restart: unless-stopped
  autoshutdown:
    image: alpine:latest
    container_name: autoshutdown
    volumes:
      - /data/scripts:/scripts
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - INACTIVITY_TIMEOUT=900
      - SNS_TOPIC_ARN=${SNS_TOPIC_ARN}
    restart: unless-stopped
    command: "/scripts/monitor-activity.sh"
EOF

    echo "Docker Compose file created successfully."
}

create_nginx_config() {
    echo "Creating NGINX configuration..."
    
    cat > /data/nginx/conf/ollama.conf << EOF
server {
    listen 80;
    server_name ${CUSTOM_DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${CUSTOM_DOMAIN};
    
    ssl_certificate /etc/letsencrypt/live/${CUSTOM_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CUSTOM_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
    
    # Main application proxy
    location / {
        proxy_pass http://open-webui:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
    
    # Serve static HTML pages for instance management
    location /starting.html {
        root /var/www/certbot;
        index starting.html;
    }
    
    location /ollama-starter.html {
        root /var/www/certbot;
        index ollama-starter.html;
    }
}
EOF

    echo "NGINX configuration created successfully."
}

create_html_pages() {
    # Get the latest API Gateway URLs
    get_api_urls
    
    echo "Creating status and starter HTML pages with URLs:"
    echo "  Start URL: $API_GATEWAY_START_URL"
    echo "  Status URL: $API_GATEWAY_STATUS_URL"
    
    # Create the starting.html page
    cat > /data/certbot/www/starting.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Starting Ollama Instance</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { 
            font-family: Arial, sans-serif; 
            max-width: 600px; 
            margin: 0 auto; 
            padding: 20px; 
            text-align: center;
            line-height: 1.6;
        }
        .loader { 
            border: 8px solid #f3f3f3; 
            border-top: 8px solid #3498db; 
            border-radius: 50%; 
            width: 50px; 
            height: 50px; 
            animation: spin 2s linear infinite; 
            margin: 30px auto; 
        }
        @keyframes spin { 
            0% { transform: rotate(0deg); } 
            100% { transform: rotate(360deg); } 
        }
        .status {
            padding: 10px;
            margin: 20px 0;
            border-radius: 5px;
        }
        .status.running {
            background-color: #d4edda;
            color: #155724;
        }
        .status.pending {
            background-color: #fff3cd;
            color: #856404;
        }
        .status.stopped {
            background-color: #f8d7da;
            color: #721c24;
        }
        .status.error {
            background-color: #f8d7da;
            color: #721c24;
        }
        button {
            background-color: #4CAF50;
            color: white;
            padding: 10px 20px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 16px;
            margin-top: 20px;
        }
        button:hover {
            background-color: #45a049;
        }
        #status-message {
            font-weight: bold;
        }
    </style>
</head>
<body>
    <h1>Starting Ollama Instance</h1>
    <div class="loader" id="loader"></div>
    <div class="status pending" id="status-container">
        <p>Current status: <span id="status-message">Checking status...</span></p>
    </div>
    <p id="description">Please wait while the Ollama instance is starting up. This may take 1-2 minutes.</p>
    <button id="refresh-btn" style="display: none;">Refresh Status</button>

    <script>
        const statusUrl = '${API_GATEWAY_STATUS_URL}';
        const startUrl = '${API_GATEWAY_START_URL}';
        const mainUrl = window.location.origin;
        let checkInterval;
        
        async function checkStatus() {
            try {
                const response = await fetch(statusUrl, {
                    method: 'GET',
                    headers: {
                        'Accept': 'application/json'
                    }
                });
                const data = await response.json();
                
                const statusContainer = document.getElementById('status-container');
                const statusMessage = document.getElementById('status-message');
                const description = document.getElementById('description');
                const loader = document.getElementById('loader');
                const refreshBtn = document.getElementById('refresh-btn');
                
                // Update UI based on instance state
                switch(data.status) {
                    case 'running':
                        statusContainer.className = 'status running';
                        statusMessage.textContent = 'Running';
                        description.textContent = 'Your Ollama instance is running! Redirecting to the main page...';
                        loader.style.display = 'none';
                        clearInterval(checkInterval);
                        setTimeout(() => { window.location.href = mainUrl; }, 2000);
                        break;
                        
                    case 'pending':
                    case 'initializing':
                        statusContainer.className = 'status pending';
                        statusMessage.textContent = data.status === 'pending' ? 'Starting' : 'Initializing';
                        description.textContent = 'Your Ollama instance is starting up. This may take 1-2 minutes.';
                        break;
                        
                    case 'stopped':
                        statusContainer.className = 'status stopped';
                        statusMessage.textContent = 'Stopped';
                        description.textContent = 'Your Ollama instance is currently stopped. Click the button below to start it.';
                        loader.style.display = 'none';
                        refreshBtn.style.display = 'inline-block';
                        refreshBtn.textContent = 'Start Instance';
                        refreshBtn.onclick = startInstance;
                        clearInterval(checkInterval);
                        break;
                        
                    default:
                        statusContainer.className = 'status pending';
                        statusMessage.textContent = data.status || 'Unknown';
                        description.textContent = data.message || 'Your Ollama instance is in transition. Please wait...';
                }
            } catch (error) {
                console.error('Error checking status:', error);
                document.getElementById('status-container').className = 'status error';
                document.getElementById('status-message').textContent = 'Error checking status';
                document.getElementById('description').textContent = 'Could not check the status of your instance. Please try again later.';
                document.getElementById('refresh-btn').style.display = 'inline-block';
                document.getElementById('refresh-btn').textContent = 'Retry';
                document.getElementById('refresh-btn').onclick = checkStatus;
                document.getElementById('loader').style.display = 'none';
                clearInterval(checkInterval);
            }
        }
        
        async function startInstance() {
            try {
                document.getElementById('refresh-btn').style.display = 'none';
                document.getElementById('loader').style.display = 'block';
                document.getElementById('status-message').textContent = 'Starting...';
                document.getElementById('description').textContent = 'Sending start request to your instance...';
                
                // Call the start API
                await fetch(startUrl);
                
                // Reset the UI for status checking
                document.getElementById('status-container').className = 'status pending';
                document.getElementById('status-message').textContent = 'Starting';
                document.getElementById('description').textContent = 'Start request sent! This may take 1-2 minutes.';
                
                // Start checking status again
                checkStatus();
                checkInterval = setInterval(checkStatus, 5000);
            } catch (error) {
                console.error('Error starting instance:', error);
                document.getElementById('status-container').className = 'status error';
                document.getElementById('status-message').textContent = 'Error starting instance';
                document.getElementById('description').textContent = 'Could not start your instance. Please try again later.';
                document.getElementById('refresh-btn').style.display = 'inline-block';
            }
        }
        
        // Initial status check
        checkStatus();
        
        // Set up interval for checking status
        checkInterval = setInterval(checkStatus, 5000);
        
        // Setup refresh button
        document.getElementById('refresh-btn').onclick = checkStatus;
    </script>
</body>
</html>
EOF

    # Create the ollama-starter.html page
    cat > /data/certbot/www/ollama-starter.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Ollama Auto-Start</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            line-height: 1.6;
        }
        .container {
            text-align: center;
            padding: 20px;
            margin: 20px 0;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #333;
        }
        p {
            color: #666;
            margin-bottom: 20px;
        }
        .button {
            display: inline-block;
            background-color: #4CAF50;
            color: white;
            padding: 12px 24px;
            text-decoration: none;
            border-radius: 4px;
            font-weight: bold;
            font-size: 16px;
            border: none;
            cursor: pointer;
        }
        .button:hover {
            background-color: #45a049;
        }
        .code {
            background-color: #f5f5f5;
            padding: 10px;
            border-radius: 4px;
            font-family: monospace;
            margin: 10px 0;
            overflow-x: auto;
        }
        .instructions {
            text-align: left;
            margin: 30px 0;
        }
        .instructions ol {
            padding-left: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Ollama Instance Auto-Start</h1>
        <p>Click the button below to start your Ollama instance if it's currently stopped.</p>
        <a href="${API_GATEWAY_START_URL}" class="button">Start Ollama Instance</a>
    </div>
    
    <div class="instructions">
        <h2>How to Use This Page</h2>
        <ol>
            <li>Bookmark this page for easy access.</li>
            <li>If you find the Ollama interface (<code>https://${CUSTOM_DOMAIN}</code>) is not responding, open this bookmark.</li>
            <li>Click the "Start Ollama Instance" button above.</li>
            <li>You will be redirected to a status page showing the instance startup progress.</li>
            <li>When the instance is fully running, you'll be automatically redirected to your Ollama WebUI.</li>
        </ol>
        
        <h2>About Auto-Start Feature</h2>
        <p>Your Ollama instance automatically shuts down after 15 minutes of inactivity to save costs. This page provides a convenient way to restart it when needed.</p>
        
        <h2>Useful Links</h2>
        <p>Direct URLs for advanced usage:</p>
        <div class="code">Start Instance: ${API_GATEWAY_START_URL}</div>
        <div class="code">Check Status: ${API_GATEWAY_STATUS_URL}</div>
    </div>
</body>
</html>
EOF

    echo "HTML pages created successfully."
}

setup_letsencrypt() {
    echo "Setting up Let's Encrypt SSL certificate..."
    
    # Create initial dummy certificates
    mkdir -p /data/certbot/conf/live/${CUSTOM_DOMAIN}
    cd /data/certbot/conf/live/${CUSTOM_DOMAIN}
    
    if [ ! -f "fullchain.pem" ]; then
        echo "Creating temporary self-signed certificate..."
        openssl req -x509 -nodes -newkey rsa:4096 -days 1 \
          -keyout privkey.pem -out fullchain.pem \
          -subj "/CN=${CUSTOM_DOMAIN}"
    fi
    
    # Add a script to request real certificates
    cat > /data/scripts/renew-cert.sh << EOF
#!/bin/bash
set -e
DOMAIN="${CUSTOM_DOMAIN}"
EMAIL="${ADMIN_EMAIL}"

echo "Requesting Let's Encrypt certificate for \$DOMAIN..."
docker compose run --rm certbot certonly --webroot \
  --webroot-path=/var/www/certbot \
  --email \$EMAIL --agree-tos --no-eff-email \
  -d \$DOMAIN

echo "Reloading Nginx to use the new certificates..."
docker exec -it nginx nginx -s reload
EOF
    
    chmod +x /data/scripts/renew-cert.sh
    echo "Let's Encrypt setup completed."
}

main() {
    echo "Starting main setup process..."
    
    # Get API Gateway URLs (will use placeholders if not available yet)
    get_api_urls
    
    # Execute each step with error checking
    attach_data_volume || { 
        echo "ERROR: Failed to attach data volume!"; 
        exit 1; 
    }
    
    setup_docker || { 
        echo "ERROR: Failed to set up Docker!"; 
        exit 1; 
    }
    
    create_monitor_script || { 
        echo "ERROR: Failed to create monitoring script!"; 
        exit 1; 
    }
    
    create_docker_compose || { 
        echo "ERROR: Failed to create Docker Compose file!"; 
        exit 1; 
    }
    
    create_nginx_config || { 
        echo "ERROR: Failed to create NGINX config!"; 
        exit 1; 
    }
    
    create_html_pages || { 
        echo "ERROR: Failed to create HTML pages!"; 
        exit 1; 
    }
    
    setup_letsencrypt || { 
        echo "ERROR: Failed to set up Let's Encrypt!"; 
        exit 1; 
    }
    
    # Start the services
    echo "Starting Docker containers..."
    cd /data
    docker compose down || true
    docker compose up -d
    
    # Request SSL certificate
    echo "Requesting SSL certificate..."
    /bin/bash /data/scripts/renew-cert.sh
    
    echo "Ollama setup completed successfully at $(date)"
    echo "You can access the Ollama WebUI at: https://${CUSTOM_DOMAIN}"
    echo "To start your instance when it's stopped, bookmark this URL: ${API_GATEWAY_START_URL}"
    
    # Send notification for successful setup
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    
    if [ -n "$SNS_TOPIC_ARN" ]; then
        aws sns publish \
          --region $REGION \
          --topic-arn "$SNS_TOPIC_ARN" \
          --message "Ollama instance $INSTANCE_ID has been successfully set up and is ready to use at https://${CUSTOM_DOMAIN}" \
          --subject "Ollama Instance Ready" || true
    fi
}

# Start the setup process
main