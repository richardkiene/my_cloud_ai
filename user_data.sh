#!/bin/bash
set -e

# Mount EBS volume for persistent storage
sudo mkfs -t ext4 /dev/sdh || true
sudo mkdir -p /data
echo '/dev/sdh /data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo mount -a

# Install dependencies
sudo apt-get update
sudo apt-get install -y \
    docker.io \
    nginx \
    certbot \
    python3-certbot-nginx \
    apache2-utils

# Start Docker
sudo systemctl enable docker
sudo systemctl start docker

# Configure data directories
sudo mkdir -p /data/ollama
sudo mkdir -p /data/open-webui

# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Configure Ollama to use persistent storage
sudo systemctl stop ollama
echo 'OLLAMA_HOST=0.0.0.0' | sudo tee /etc/ollama/env
echo 'OLLAMA_MODELS_PATH=/data/ollama' | sudo tee -a /etc/ollama/env
sudo systemctl start ollama

# Install Open-WebUI
sudo docker run -d \
    --name open-webui \
    --restart unless-stopped \
    -v /data/open-webui:/root/.cache \
    -p 3000:8080 \
    -e OLLAMA_API_BASE_URL=http://host.docker.internal:11434/api \
    --add-host host.docker.internal:host-gateway \
    ghcr.io/open-webui/open-webui:main

# Configure Nginx
cat << EOF | sudo tee /etc/nginx/sites-available/ollama
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/ollama /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Set up authentication
echo "admin:$(htpasswd -nbB admin '${PASSWORD}')" | sudo tee /etc/nginx/.htpasswd

# Get SSL certificate
sudo certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m ${EMAIL}

# Set up auto-renewal
echo "0 0 * * * root certbot renew --quiet" | sudo tee -a /etc/crontab

# Set up instance auto-shutdown
cat << 'EOF' | sudo tee /usr/local/bin/check-activity.sh
#!/bin/bash
# Check CPU usage over last 15 minutes
USAGE=$(top -bn2 | grep "Cpu(s)" | tail -1 | awk '{print $2}')
if (( $(echo "$USAGE < 5.0" | bc -l) )); then
    sudo poweroff
fi
EOF

sudo chmod +x /usr/local/bin/check-activity.sh
echo "*/15 * * * * root /usr/local/bin/check-activity.sh" | sudo tee -a /etc/crontab

# Notify on startup
aws sns publish \
    --topic-arn "${SNS_TOPIC}" \
    --subject "Ollama Instance Started" \
    --message "Your Ollama instance has started and is ready at https://${DOMAIN}"