#!/bin/bash
set -ex

# Enable logging
exec > >(tee /home/ubuntu/packer-provisioning.log) 2>&1
echo "Starting provisioning script: $(date)"

# Update the system
echo "Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y

# Add NVIDIA repository
echo "Adding NVIDIA repository..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Update package lists again after adding NVIDIA repository
echo "Updating package lists after adding NVIDIA repository..."
sudo apt-get update -y

# Install dependencies including NVIDIA drivers
echo "Installing dependencies..."
sudo apt-get install -y \
    docker.io \
    docker-compose \
    nvme-cli \
    nvidia-container-toolkit \
    nvidia-driver-535 \
    nvidia-utils-535 \
    jq \
    zip \
    awscli

# Add ubuntu user to docker group
sudo usermod -aG docker ubuntu
echo "Added ubuntu user to docker group"

# Add ubuntu user to docker group
sudo usermod -aG docker ubuntu

# Ensure NVIDIA modules load at boot
echo "nvidia" | sudo tee -a /etc/modules

# Copy the updated scripts to the system
sudo mkdir -p /usr/local/bin
sudo cp /home/ubuntu/ollama-setup.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/ollama-setup.sh

# Create systemd service for Ollama setup
sudo tee /etc/systemd/system/ollama-setup.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Setup Service
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ollama-setup.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
sudo systemctl daemon-reload
sudo systemctl enable ollama-setup.service

# Create docker-compose.yml in /home/ubuntu so it can be copied to the EBS volume later
sudo mkdir -p /home/ubuntu/ollama
sudo tee /home/ubuntu/ollama/docker-compose.yml > /dev/null << 'EOF'
# This file will be copied to /data during setup
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
    runtime: nvidia
    ports:
      - "11434:11434"
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
    volumes:
      - /data/ollama/models:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
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
      - INACTIVITY_TIMEOUT=900  # 15 minutes in seconds
    restart: unless-stopped
    command: "/scripts/monitor-activity.sh"
EOF

# Cleanup
echo "Cleaning up..."
sudo apt-get clean
sudo apt-get autoremove -y

echo "Provisioning completed: $(date)"