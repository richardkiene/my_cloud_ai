#!/bin/bash
set -ex

# These variables will be substituted by Terraform
CUSTOM_DOMAIN="${CUSTOM_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
WEBUI_PASSWORD="${WEBUI_PASSWORD}"
API_GATEWAY_STATUS_URL="${API_GATEWAY_STATUS_URL}"
API_GATEWAY_START_URL="${API_GATEWAY_START_URL}"
STARTING_HTML_GZIP="${STARTING_HTML_GZIP}"
STARTER_HTML_GZIP="${STARTER_HTML_GZIP}"

# Log output
exec > >(tee /var/log/user-data.log) 2>&1
echo "Starting user data script at $(date)"

# Create necessary directories
mkdir -p /data/ollama/models /data/open-webui /data/nginx/conf /data/certbot/conf /data/certbot/www /data/scripts /data/docker

# Mount volume function
mount_data_volume() {
  local EBS_DEVICE=""
  
  # Check if already mounted
  if mountpoint -q /data; then
    echo "Volume already mounted at /data"
    return 0
  fi
  
  # Find volume - improved detection for NVMe devices
  # First, check traditional device names
  for dev in /dev/sdh /dev/xvdh; do
    if [ -e "$dev" ] && [ "$(lsblk -no MOUNTPOINT $dev 2>/dev/null)" == "" ]; then
      EBS_DEVICE="$dev"
      break
    fi
  done
  
  # If not found, check NVMe devices and look for the 256GB volume we expect
  if [ -z "$EBS_DEVICE" ]; then
    for dev in $(ls /dev/nvme*n1 2>/dev/null); do
      # Check if device exists and isn't mounted
      if [ -e "$dev" ] && [ "$(lsblk -no MOUNTPOINT $dev 2>/dev/null)" == "" ]; then
        # Check size - we're looking for our 256GB volume
        local SIZE=$(lsblk -no SIZE $dev | tr -d 'G')
        if [[ "$SIZE" == "256" || "$SIZE" == "256.0" || "$SIZE" == "256G" ]]; then
          EBS_DEVICE="$dev"
          break
        fi
      fi
    done
  fi
  
  # Mount it
  if [ -z "$EBS_DEVICE" ]; then
    echo "ERROR: No EBS volume detected!"
    lsblk
    return 1
  fi
  
  echo "EBS volume found at $EBS_DEVICE"
  mkdir -p /data
  
  # Check if the device has a filesystem already
  if file -s $EBS_DEVICE | grep -q "data"; then
    echo "Formatting new filesystem on $EBS_DEVICE"
    mkfs.ext4 -F $EBS_DEVICE
  else
    echo "Filesystem already exists on $EBS_DEVICE"
  fi
  
  mount $EBS_DEVICE /data
  echo "$EBS_DEVICE /data ext4 defaults,nofail 0 2" >> /etc/fstab
  
  # Re-create directories on mounted volume
  mkdir -p /data/ollama/models /data/open-webui /data/nginx/conf /data/certbot/conf /data/certbot/www /data/scripts /data/docker
}

# Set up Docker
setup_docker() {
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << 'EOF'
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
  systemctl restart docker
}

# Create docker-compose.yml
create_docker_compose() {
  cat > /data/docker-compose.yml << 'EOF'
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
    command: "/bin/sh -c 'while :; do sleep 6h & wait $${!}; nginx -s reload; done & nginx -g \"daemon off;\"'"
  certbot:
    image: certbot/certbot
    container_name: certbot
    volumes:
      - /data/certbot/conf:/etc/letsencrypt
      - /data/certbot/www:/var/www/certbot
    restart: unless-stopped
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
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
    restart: unless-stopped
    command: "/scripts/monitor-activity.sh"
EOF
}

# Create monitoring script
create_monitor_script() {
  cat > /data/scripts/monitor-activity.sh << 'EOF'
#!/bin/sh
set -e
apk add --no-cache docker curl aws-cli
if [ ! -S /var/run/docker.sock ]; then
  echo "ERROR: Docker socket not accessible!"
  exit 1
fi
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "Starting activity monitor for instance $INSTANCE_ID"
echo "Inactivity timeout set to $INACTIVITY_TIMEOUT seconds"
last_activity=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  if sudo docker exec ollama grep -q "POST /api" /var/log/ollama.log 2>/dev/null; then
    last_activity=$CURRENT_TIME
    sudo docker exec ollama truncate -s 0 /var/log/ollama.log
  fi
  if sudo docker logs --since 1m open-webui 2>&1 | grep -q "GET /"; then
    last_activity=$CURRENT_TIME
  fi
  inactive_time=$((CURRENT_TIME - last_activity))
  if [ $inactive_time -gt $INACTIVITY_TIMEOUT ]; then
    echo "Instance has been inactive for $inactive_time seconds, shutting down..."
    aws sns publish \
      --region $REGION \
      --topic-arn "arn:aws:sns:$REGION:$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .accountId):ollama-alerts" \
      --message "Ollama instance $INSTANCE_ID is shutting down due to inactivity." \
      --subject "Ollama Instance Auto-Shutdown" || true
    aws ec2 stop-instances --region $REGION --instance-ids $INSTANCE_ID
    break
  fi
  if [ $((CURRENT_TIME % 300)) -lt 10 ]; then
    echo "Activity monitor: Instance has been inactive for $inactive_time seconds"
  fi
  sleep 60
done
EOF
  chmod +x /data/scripts/monitor-activity.sh
}

# Create nginx configuration and startup scripts
create_nginx_config() {
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

  cat > /data/scripts/init-letsencrypt.sh << 'EOF'
#!/bin/bash
set -e
DOMAIN=$1
EMAIL=$2
mkdir -p /data/certbot/conf/live/$DOMAIN
cd /data/certbot/conf/live/$DOMAIN
if [ ! -f "fullchain.pem" ]; then
  echo "Creating dummy certificates..."
  openssl req -x509 -nodes -newkey rsa:4096 -days 1 -keyout privkey.pem -out fullchain.pem -subj "/CN=localhost"
fi
cd /data && sudo docker-compose up -d nginx
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
  chmod +x /data/scripts/init-letsencrypt.sh
}

# Create the web pages from gzipped base64 content
create_webpages() {
  # Create directories
  mkdir -p /data/certbot/www
  
  # Decompress starting.html from gzipped base64
  echo "$STARTING_HTML_GZIP" | base64 -d | gunzip > /data/certbot/www/starting.html
  
  # Replace placeholders
  sed -i "s|APISTATUS|${API_GATEWAY_STATUS_URL}|g" /data/certbot/www/starting.html
  sed -i "s|APISTART|${API_GATEWAY_START_URL}|g" /data/certbot/www/starting.html
  
  # Decompress ollama-starter.html from gzipped base64
  echo "$STARTER_HTML_GZIP" | base64 -d | gunzip > /data/certbot/www/ollama-starter.html
  
  # Replace placeholders
  sed -i "s|APISTART|${API_GATEWAY_START_URL}|g" /data/certbot/www/ollama-starter.html
  sed -i "s|APISTATUS|${API_GATEWAY_STATUS_URL}|g" /data/certbot/www/ollama-starter.html
  sed -i "s|DOMAIN|${CUSTOM_DOMAIN}|g" /data/certbot/www/ollama-starter.html
}

# Main execution
verify_nvidia() {
  if ! nvidia-smi > /dev/null 2>&1; then
    echo "ERROR: NVIDIA drivers failed to load!"
    exit 1
  fi
  echo "NVIDIA drivers loaded successfully."
}

main() {
  verify_nvidia
  mount_data_volume
  setup_docker
  export WEBUI_PASSWORD="$WEBUI_PASSWORD"
  create_docker_compose
  create_monitor_script
  create_nginx_config
  create_webpages
  
  echo "Starting Docker containers..."
  cd /data && sudo docker-compose down || true
  cd /data && sudo docker-compose up -d
  
  sudo bash /data/scripts/init-letsencrypt.sh "$CUSTOM_DOMAIN" "$ADMIN_EMAIL"
  
  echo "Ollama setup completed at $(date)"
  echo "You can access the Ollama WebUI at: https://$CUSTOM_DOMAIN"
  echo "To start your instance when it's stopped, bookmark this URL: ${API_GATEWAY_START_URL}"
}

main