#!/bin/bash
set -e

# Enable logging to a file in the ubuntu user's home directory
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

# Install basic dependencies (common for all instance types)
echo "Installing dependencies..."
sudo apt-get install -y \
    docker.io \
    docker-compose \
    nginx \
    certbot \
    python3-certbot-nginx \
    apache2-utils \
    nvme-cli

# Create script to detect and install NVIDIA drivers on first boot
cat > /tmp/setup_nvidia.sh << 'NVIDIA_EOF'
#!/bin/bash
set -e

# Skip if already run
if [ -f /var/lib/nvidia-setup-complete ]; then
    echo "NVIDIA setup already completed."
    exit 0
fi

# Log to a file
exec > >(tee /var/log/nvidia-setup.log) 2>&1
echo "Checking for NVIDIA GPU: $(date)"

# Only install NVIDIA drivers if GPU is present
if sudo lspci | grep -i nvidia > /dev/null; then
    echo "NVIDIA GPU detected, installing drivers..."
    sudo apt-get update -y
    sudo apt-get install -y nvidia-container-toolkit nvidia-driver-535 nvidia-utils-535

    # Configure Docker to use NVIDIA runtime
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json << 'EOF'
{
    "storage-driver": "overlay2",
    "max-concurrent-downloads": 50,
    "max-concurrent-uploads": 50,
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF

    # Restart Docker to apply new configuration
    sudo systemctl daemon-reload
    sudo systemctl restart docker

    # Test NVIDIA driver
    if sudo nvidia-smi; then
        echo "NVIDIA driver successfully installed"
    else
        echo "NVIDIA driver installation failed"
        exit 1
    fi
else
    echo "No NVIDIA GPU detected, skipping driver installation."
fi

# Mark as complete to avoid running twice
sudo touch /var/lib/nvidia-setup-complete
NVIDIA_EOF

# Make script executable and move to appropriate location
sudo chmod +x /tmp/setup_nvidia.sh
sudo mv /tmp/setup_nvidia.sh /usr/local/bin/setup_nvidia.sh

# Create systemd service to run the script on first boot
cat > /tmp/nvidia-setup.service << 'EOF'
[Unit]
Description=Setup NVIDIA drivers if GPU is present
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup_nvidia.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/nvidia-setup.service /etc/systemd/system/
sudo systemctl enable nvidia-setup.service

# Configure Docker to use NVIDIA runtime
echo "Configuring Docker with NVIDIA runtime..."
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
    "storage-driver": "overlay2",
    "max-concurrent-downloads": 50,
    "max-concurrent-uploads": 50,
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF

# Start and enable Docker service
echo "Starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

# Restart Docker to apply new configuration
echo "Restarting Docker service..."
sudo systemctl daemon-reload
sudo systemctl restart docker

# Create data directories
echo "Creating data directories..."
sudo mkdir -p /data/ollama
sudo mkdir -p /data/open-webui

# Configure Nginx default site for later customization
echo "Setting up Nginx default configuration..."
sudo tee /etc/nginx/sites-available/ollama-template > /dev/null <<EOF
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# Cleanup APT cache to reduce image size
echo "Cleaning up..."
sudo apt-get clean
sudo apt-get autoremove -y

echo "Provisioning completed: $(date)"