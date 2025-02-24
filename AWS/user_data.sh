#!/bin/bash
set -e

# These variables will be replaced by Terraform
CUSTOM_DOMAIN="${custom_domain}"
ADMIN_EMAIL="${admin_email}"

# Redirect all output to a log file for debugging
exec > /var/log/user-data.log 2>&1

# Function to log messages
echo_log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

echo_log "Starting user data script..."
echo_log "Custom Domain: $CUSTOM_DOMAIN :: Admin Email: $ADMIN_EMAIL"

# The NVIDIA setup happens automatically via systemd service if GPU is present

# Set up instance storage for Docker if available
if [ -b /dev/nvme1n1 ]; then
    echo_log "Setting up instance store for Docker..."
    sudo mkfs -t ext4 /dev/nvme1n1
    sudo mkdir -p /mnt/instance-store
    sudo mount /dev/nvme1n1 /mnt/instance-store
    echo '/dev/nvme1n1 /mnt/instance-store ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
    
    # Move Docker to instance store for better performance
    if [ -d "/mnt/instance-store" ]; then
        echo_log "Moving Docker to instance store..."
        sudo mkdir -p /mnt/instance-store/docker
        sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
    "data-root": "/mnt/instance-store/docker",
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
        sudo systemctl restart docker
    fi
fi

# Configure Nginx with the custom domain
echo_log "Configuring Nginx for custom domain: $CUSTOM_DOMAIN"
sudo cp /etc/nginx/sites-available/ollama-template /etc/nginx/sites-available/ollama
sudo sed -i "s/DOMAIN_PLACEHOLDER/$CUSTOM_DOMAIN/g" /etc/nginx/sites-available/ollama
sudo ln -sf /etc/nginx/sites-available/ollama /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx

# Start the Docker containers
echo_log "Starting Docker containers..."
cd /data && sudo docker-compose up -d || { echo_log "Docker containers failed to start!"; exit 1; }

# Obtain SSL certificate
echo_log "Setting up Certbot..."
if [[ -n "$CUSTOM_DOMAIN" ]]; then
    sudo certbot --nginx -d $CUSTOM_DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL
else
    echo_log "Skipping Certbot setup due to missing $CUSTOM_DOMAIN"
fi

# Enable automatic certificate renewal
echo_log "Configuring auto-renewal for SSL certificates..."
echo "0 0 * * * root certbot renew --quiet" | sudo tee -a /etc/crontab

echo_log "User data script execution completed successfully."