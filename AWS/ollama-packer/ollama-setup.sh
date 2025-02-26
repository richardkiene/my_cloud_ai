#!/bin/bash
set -ex

# Log all output
exec > >(tee /var/log/ollama-setup.log) 2>&1

echo "Starting Ollama setup at $(date)"

# Ensure NVIDIA driver is loaded
if ! lsmod | grep -q nvidia; then
  echo "Loading NVIDIA kernel module..."
  modprobe nvidia
  
  # Verify NVIDIA driver is working
  if ! nvidia-smi > /dev/null 2>&1; then
    echo "ERROR: NVIDIA drivers failed to load!"
    exit 1
  fi
  echo "NVIDIA drivers loaded successfully."
fi

echo "Detecting EBS volume..."
EBS_DEVICE=""

# Check if /data is already mounted
if mountpoint -q /data; then
    echo "Volume already mounted at /data, continuing with setup..."
else
    # Original detection logic for unmounted volumes
    # Check for traditional block devices first
    if [ -e /dev/sdh ]; then
        EBS_DEVICE="/dev/sdh"
    elif [ -e /dev/xvdh ]; then
        EBS_DEVICE="/dev/xvdh"
    else
        # Check for NVMe devices and exclude the root volume
        for dev in $(ls /dev/nvme*n1 2>/dev/null); do
            if [ "$(lsblk -no MOUNTPOINT $dev)" == "" ]; then
                # Device is not mounted, assume it's the correct EBS volume
                EBS_DEVICE="$dev"
                break
            fi
        done
    fi

    if [ -z "$EBS_DEVICE" ]; then
        echo "ERROR: No EBS volume detected!"
        lsblk
        exit 1
    fi

    echo "EBS volume found at $EBS_DEVICE"

    # Format and mount the volume
    echo "Formatting and mounting $EBS_DEVICE..."
    sudo mkfs.ext4 -F $EBS_DEVICE
    sudo mkdir -p /data
    sudo mount $EBS_DEVICE /data
    echo "$EBS_DEVICE /data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
fi

# Create necessary directories
mkdir -p /data/ollama/models
mkdir -p /data/open-webui
mkdir -p /data/nginx/conf
mkdir -p /data/certbot/conf
mkdir -p /data/certbot/www
mkdir -p /data/scripts
mkdir -p /data/docker

# Create the Docker daemon configuration to store images on the persistent volume
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
    "data-root": "/data/docker",
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    },
    "storage-driver": "overlay2"
}
EOF

# Restart Docker to apply the new configuration
if systemctl is-active --quiet docker; then
  echo "Restarting Docker service to apply new configuration..."
  systemctl restart docker
fi

# Copy docker-compose file if it exists
if [ -f "/home/ubuntu/ollama/docker-compose.yml" ]; then
  echo "Copying docker-compose.yml to /data..."
  cp /home/ubuntu/ollama/docker-compose.yml /data/
fi

# Get the domain information
DOMAIN=${1:-$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)}
EMAIL=${2:-"admin@example.com"}
WEBUI_PASSWORD=${3:-"admin"}

# Get API Gateway URLs from environment variables or EC2 tags
if [ -z "$API_GATEWAY_STATUS_URL" ] || [ -z "$API_GATEWAY_START_URL" ]; then
  echo "API Gateway URLs not provided via environment variables, attempting to get from EC2 tags..."
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
  
  API_GATEWAY_STATUS_URL=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=ApiGatewayStatusUrl" --query "Tags[0].Value" --output text --region $REGION)
  API_GATEWAY_START_URL=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=ApiGatewayStartUrl" --query "Tags[0].Value" --output text --region $REGION)
  
  # If still not found, use default placeholder values
  if [ "$API_GATEWAY_STATUS_URL" == "None" ]; then
    API_GATEWAY_STATUS_URL="https://example.execute-api.region.amazonaws.com/prod/status"
  fi
  
  if [ "$API_GATEWAY_START_URL" == "None" ]; then
    API_GATEWAY_START_URL="https://example.execute-api.region.amazonaws.com/prod/start"
  fi
fi

echo "Configuring for domain: $DOMAIN"
echo "Using API Gateway Status URL: $API_GATEWAY_STATUS_URL"
echo "Using API Gateway Start URL: $API_GATEWAY_START_URL"

# Export password for docker-compose
export WEBUI_PASSWORD

# Create Nginx configuration for the domain
sudo tee /data/nginx/conf/ollama.conf > /dev/null << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};
    
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    location / {
        proxy_pass http://open-webui:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# Create init-letsencrypt.sh script
sudo tee /data/scripts/init-letsencrypt.sh > /dev/null << 'EOF'
#!/bin/bash
set -e

# Get domain and email from parameters
DOMAIN=$1
EMAIL=$2

# Create dummy certificates for Nginx to start
mkdir -p /data/certbot/conf/live/$DOMAIN
cd /data/certbot/conf/live/$DOMAIN

# Check if we already have certificates
if [ ! -f "fullchain.pem" ]; then
  echo "Creating dummy certificates..."
  openssl req -x509 -nodes -newkey rsa:4096 -days 1 \
    -keyout privkey.pem -out fullchain.pem -subj "/CN=localhost"
fi

# Start Nginx
cd /data && sudo docker-compose up -d nginx

# Request real certificates
if [[ ! "$DOMAIN" =~ "amazonaws.com" ]] && [[ ! "$DOMAIN" =~ "compute" ]]; then
  echo "Requesting Let's Encrypt certificate for $DOMAIN..."
  cd /data && sudo docker-compose run --rm certbot certonly --webroot \
    --webroot-path=/var/www/certbot \
    --email $EMAIL --agree-tos --no-eff-email \
    -d $DOMAIN
  
  echo "Reloading Nginx to use the new certificates..."
  sudo docker exec -it nginx nginx -s reload
else
  echo "Using EC2 hostname, skipping SSL setup."
fi
EOF

sudo chmod +x /data/scripts/init-letsencrypt.sh

# Create activity monitoring script for auto-shutdown
sudo tee /data/scripts/monitor-activity.sh > /dev/null << 'EOF'
#!/bin/sh
set -e

# Install required tools
apk add --no-cache docker curl aws-cli

# Ensure we can access Docker
if [ ! -S /var/run/docker.sock ]; then
  echo "ERROR: Docker socket not accessible!"
  exit 1
fi

# Get the instance ID
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

echo "Starting activity monitor for instance $INSTANCE_ID"
echo "Inactivity timeout set to $INACTIVITY_TIMEOUT seconds"

last_activity=$(date +%s)

while true; do
  # Check API activity on ollama container
  CURRENT_TIME=$(date +%s)
  
  # Check for API calls to ollama 
  if sudo docker exec ollama grep -q "POST /api" /var/log/ollama.log 2>/dev/null; then
    last_activity=$CURRENT_TIME
    sudo docker exec ollama truncate -s 0 /var/log/ollama.log
  fi
  
  # Check WebUI access
  if sudo docker logs --since 1m open-webui 2>&1 | grep -q "GET /"; then
    last_activity=$CURRENT_TIME
  fi
  
  # Calculate inactivity time
  inactive_time=$((CURRENT_TIME - last_activity))
  
  # If inactive for too long, initiate shutdown
  if [ $inactive_time -gt $INACTIVITY_TIMEOUT ]; then
    echo "Instance has been inactive for $inactive_time seconds, shutting down..."
    
    # Publish alert to SNS if configured
    aws sns publish \
      --region $REGION \
      --topic-arn "arn:aws:sns:$REGION:$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .accountId):ollama-alerts" \
      --message "Ollama instance $INSTANCE_ID is shutting down due to inactivity." \
      --subject "Ollama Instance Auto-Shutdown" || true
    
    # Initiate proper system shutdown
    aws ec2 stop-instances --region $REGION --instance-ids $INSTANCE_ID
    break
  fi
  
  # Log status every 5 minutes
  if [ $((CURRENT_TIME % 300)) -lt 10 ]; then
    echo "Activity monitor: Instance has been inactive for $inactive_time seconds"
  fi
  
  # Sleep for a bit
  sleep 60
done
EOF

sudo chmod +x /data/scripts/monitor-activity.sh

# Create the enhanced "starting" page for auto-start functionality
mkdir -p /data/certbot/www
cat > /data/certbot/www/starting.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Starting Ollama Instance</title>
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
    <p><a href="/" id="check-link">Check if it's ready now</a></p>
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
                        statusContainer.className = 'status pending';
                        statusMessage.textContent = 'Starting';
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
                        description.textContent = 'Your Ollama instance is in transition. Please wait...';
                }
            } catch (error) {
                console.error('Error checking status:', error);
                document.getElementById('status-container').className = 'status error';
                document.getElementById('status-message').textContent = 'Error checking status';
                document.getElementById('description').textContent = 'Could not check the status of your instance. Please try again later.';
                document.getElementById('refresh-btn').style.display = 'inline-block';
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

# Create bookmark HTML file that users can download
cat > /data/certbot/www/ollama-starter.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Ollama Auto-Start</title>
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
            padding: 10px 20px;
            text-decoration: none;
            border-radius: 4px;
            font-weight: bold;
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
            <li>If you find the Ollama interface (<code>https://${DOMAIN}</code>) is not responding, open this bookmark.</li>
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

# Ensure Docker is configured to use the nvidia runtime
sudo nvidia-ctk runtime configure --runtime=docker

# Start the containers
echo "Starting Docker containers..."
cd /data && sudo docker-compose down || true
cd /data && sudo docker-compose up -d

# Initialize Letsencrypt certificates
sudo bash /data/scripts/init-letsencrypt.sh "$DOMAIN" "$EMAIL"

# Verify containers are running
if sudo docker ps | grep -q "ollama"; then
  echo "Ollama container is running."
else
  echo "ERROR: Ollama container failed to start!"
fi

if sudo docker ps | grep -q "open-webui"; then
  echo "Open-WebUI container is running."
else
  echo "ERROR: Open-WebUI container failed to start!"
fi

if sudo docker ps | grep -q "nginx"; then
  echo "Nginx container is running."
else
  echo "ERROR: Nginx container failed to start!"
fi

echo "Ollama setup completed at $(date)"
echo "You can access the Ollama WebUI at: https://$DOMAIN"
echo "To start your instance when it's stopped, bookmark this URL: ${API_GATEWAY_START_URL}"
echo "You can also download the starter bookmark from: https://$DOMAIN/ollama-starter.html"