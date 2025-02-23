import requests
import time
import os

# RunPod API Key
RUNPOD_API_KEY = "your-runpod-api-key"
BASE_URL = "https://api.runpod.io/graphql"

# Instance Configuration
INSTANCE_TYPE = "NVIDIA-RTX4090"
DOCKER_IMAGE = "ollama/open-webui"
VOLUME_ID = "your-persistent-volume-id"
AUTO_SHUTDOWN_THRESHOLD = 900
DOMAIN_NAME = "yourdomain.com"
EMAIL = "your-email@example.com"

# Authentication Configuration
ADMIN_USERNAME = "admin"
ADMIN_PASSWORD = "your-secure-password"

# Headers for API Requests
HEADERS = {
    "Authorization": f"Bearer {RUNPOD_API_KEY}",
    "Content-Type": "application/json"
}

# Function to create an instance
def create_instance():
    response = requests.post(BASE_URL, json={
        "query": """
        mutation CreateInstance($input: CreateInstanceInput!) {
            createInstance(input: $input) {
                id
                status
                publicIp
            }
        }
        """,
        "variables": {
            "input": {
                "gpuType": INSTANCE_TYPE,
                "imageName": DOCKER_IMAGE,
                "volumeId": VOLUME_ID,
                "ports": [{"port": 80, "isPublic": True}, {"port": 443, "isPublic": True}]
            }
        }
    }, headers=HEADERS)
    
    if response.status_code == 200:
        data = response.json()
        instance_id = data["data"]["createInstance"]["id"]
        public_ip = data["data"]["createInstance"]["publicIp"]
        print(f"Instance created successfully! ID: {instance_id}")
        return instance_id, public_ip
    else:
        print(f"Error creating instance: {response.text}")
        return None, None

# Function to configure SSL, Nginx, and Authentication
def setup_ssl_and_auth(public_ip):
    print("Setting up Nginx, SSL, and Basic Authentication...")
    
    setup_script = f"""
    # Install dependencies
    sudo apt update && sudo apt install -y certbot nginx apache2-utils docker.io
    
    # Create authentication credentials
    echo "{ADMIN_USERNAME}:$(openssl passwd -apr1 {ADMIN_PASSWORD})" | sudo tee /etc/nginx/.htpasswd
    
    # Start Open-WebUI in Docker
    sudo docker pull ollama/open-webui
    sudo docker run -d --name open-webui -p 3000:3000 ollama/open-webui

    # Configure Nginx for reverse proxy with authentication
    sudo bash -c 'cat > /etc/nginx/sites-available/open-webui <<EOF
server {{
    listen 80;
    server_name {DOMAIN_NAME};

    location / {{
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Require authentication
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }}
}}
EOF'

    # Enable the Nginx configuration
    sudo ln -s /etc/nginx/sites-available/open-webui /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl restart nginx

    # Obtain and install SSL certificate
    sudo certbot --nginx -d {DOMAIN_NAME} --email {EMAIL} --non-interactive --agree-tos
    sudo systemctl restart nginx
    """

    os.system(f"ssh root@{public_ip} '{setup_script}'")
    print("SSL and Authentication setup complete. Access at: https://{DOMAIN_NAME}")

# Function to get instance status
def get_instance_status(instance_id):
    while True:
        response = requests.post(BASE_URL, json={
            "query": """
            query GetInstanceStatus($id: ID!) {
                instance(id: $id) {
                    id
                    status
                    publicIp
                }
            }
            """,
            "variables": {"id": instance_id}
        }, headers=HEADERS)
        
        if response.status_code == 200:
            data = response.json()
            instance_status = data["data"]["instance"]["status"]
            public_ip = data["data"]["instance"]["publicIp"]
            print(f"Instance Status: {instance_status}")
            if instance_status == "RUNNING":
                print(f"Instance Public IP: {public_ip}")
                setup_ssl_and_auth(public_ip)
                return public_ip
        else:
            print(f"Error getting status: {response.text}")
        
        time.sleep(5)

# Deploy instance
instance_id, public_ip = create_instance()
if instance_id:
    public_ip = get_instance_status(instance_id)
    print(f"Ollama & Open-WebUI secured at: https://{DOMAIN_NAME}")
