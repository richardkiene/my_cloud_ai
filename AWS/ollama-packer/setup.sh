#!/bin/bash
set -e

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
    nginx \
    certbot \
    python3-certbot-nginx \
    apache2-utils \
    nvme-cli \
    nvidia-container-toolkit \
    nvidia-driver-535 \
    nvidia-utils-535

# Ensure NVIDIA modules load at boot
echo "nvidia" | sudo tee -a /etc/modules

# Create the setup script
sudo mkdir -p /usr/local/bin
sudo tee /usr/local/bin/ollama-setup.sh > /dev/null << 'EOF'
#!/bin/bash
set -e

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

# Configure Nginx
if [ -f "/etc/nginx/sites-available/ollama-template" ]; then
  # Get the hostname or use a provided domain
  DOMAIN=${1:-$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)}
  EMAIL=${2:-"admin@example.com"}
  
  echo "Configuring Nginx for domain: $DOMAIN"
  
  # Create configuration from template
  cp /etc/nginx/sites-available/ollama-template /etc/nginx/sites-available/ollama
  sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/sites-available/ollama
  
  # Enable the site
  ln -sf /etc/nginx/sites-available/ollama /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  
  # Test and restart Nginx
  nginx -t && systemctl restart nginx
  echo "Nginx configured successfully."
  
  # Set up SSL certificate if domain is provided and not an EC2 hostname
  if [[ ! "$DOMAIN" =~ "amazonaws.com" ]] && [[ ! "$DOMAIN" =~ "compute" ]]; then
    echo "Setting up SSL certificate for $DOMAIN..."
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
    echo "SSL certificate installed successfully."
    
    # Auto renewal
    echo "0 0 * * * root certbot renew --quiet" | tee -a /etc/crontab
  else
    echo "Using EC2 hostname, skipping SSL setup."
  fi
fi

# Start the containers
echo "Starting Docker containers..."
cd /data && docker-compose down || true
cd /data && docker-compose up -d

# Verify containers are running
if docker ps | grep -q "ollama"; then
  echo "Ollama container is running."
else
  echo "ERROR: Ollama container failed to start!"
fi

if docker ps | grep -q "open-webui"; then
  echo "Open-WebUI container is running."
else
  echo "ERROR: Open-WebUI container failed to start!"
fi

echo "Ollama setup completed at $(date)"
EOF

sudo chmod +x /usr/local/bin/ollama-setup.sh

# Create systemd service
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

# Configure Nginx template
sudo tee /etc/nginx/sites-available/ollama-template > /dev/null << 'EOF'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
EOF

# Create docker-compose.yml with correct environment variable
sudo mkdir -p /data
sudo tee /data/docker-compose.yml > /dev/null << 'EOF'
version: '3'
services:
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
      - /data/ollama:/root/.ollama
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
    volumes:
      - /data/open-webui:/root/.cache
    depends_on:
      - ollama
    restart: unless-stopped
EOF

# Create data directories
sudo mkdir -p /data/ollama
sudo mkdir -p /data/open-webui

# Enable the service
sudo systemctl daemon-reload
sudo systemctl enable ollama-setup.service

# Cleanup
echo "Cleaning up..."
sudo apt-get clean
sudo apt-get autoremove -y

echo "Provisioning completed: $(date)"