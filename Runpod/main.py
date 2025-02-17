import requests
import time
import os

# RunPod API Key
RUNPOD_API_KEY = "your-runpod-api-key"
BASE_URL = "https://api.runpod.io/graphql"

# Instance Configuration
INSTANCE_TYPE = "NVIDIA-RTX4090"
DOCKER_IMAGE = "ollama/open-webui"
VOLUME_ID = "your-persistent-volume-id"  # Set if using persistent storage
AUTO_SHUTDOWN_THRESHOLD = 900  # 15 minutes of inactivity
DOMAIN_NAME = "yourdomain.com"  # Set your domain for Let's Encrypt SSL

# Headers for API Requests
HEADERS = {
    "Authorization": f"Bearer {RUNPOD_API_KEY}",
    "Content-Type": "application/json"
}

# GraphQL Query to Launch an Instance
CREATE_INSTANCE_QUERY = {
    "query": """
    mutation CreateInstance($input: CreateInstanceInput!) {
        createInstance(input: $input) {
            id
            status
            publicIp
            volume {
                id
                mountPath
            }
        }
    }
    """,
    "variables": {
        "input": {
            "gpuType": INSTANCE_TYPE,
            "imageName": DOCKER_IMAGE,
            "volumeId": VOLUME_ID,
            "ports": [{"port": 80, "isPublic": True}, {"port": 443, "isPublic": True}],
            "env": {"AUTH_PASSWORD": "your-secure-password"}
        }
    }
}

# Function to create an instance
def create_instance():
    response = requests.post(BASE_URL, json=CREATE_INSTANCE_QUERY, headers=HEADERS)
    if response.status_code == 200:
        data = response.json()
        instance_id = data["data"]["createInstance"]["id"]
        volume_path = data["data"]["createInstance"].get("volume", {}).get("mountPath", "Not Mounted")
        print(f"Instance created successfully! ID: {instance_id}")
        print(f"Persistent storage mounted at: {volume_path}")
        return instance_id
    else:
        print(f"Error creating instance: {response.text}")
        return None

# Function to install and configure Let's Encrypt
def setup_ssl(public_ip):
    print("Setting up Let's Encrypt SSL certificate...")
    os.system(f"ssh root@{public_ip} 'sudo apt update && sudo apt install -y certbot nginx' ")
    os.system(f"ssh root@{public_ip} 'sudo certbot --nginx -d {DOMAIN_NAME} --non-interactive --agree-tos -m your-email@example.com' ")
    os.system(f"ssh root@{public_ip} 'sudo systemctl restart nginx' ")
    print("SSL setup complete. Access Open-WebUI securely via HTTPS.")

# Function to monitor instance status
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
                setup_ssl(public_ip)
                return public_ip
        else:
            print(f"Error getting status: {response.text}")
        
        time.sleep(5)

# Function to check for inactivity and shutdown instance
def auto_shutdown(instance_id):
    last_activity_time = time.time()
    while True:
        time.sleep(60)
        # Placeholder for checking actual activity (e.g., monitoring requests/logs)
        if time.time() - last_activity_time > AUTO_SHUTDOWN_THRESHOLD:
            print("No activity detected. Shutting down instance.")
            shutdown_instance(instance_id)
            break

# Function to shut down an instance
def shutdown_instance(instance_id):
    response = requests.post(BASE_URL, json={
        "query": """
        mutation StopInstance($id: ID!) {
            stopInstance(id: $id) {
                id
                status
            }
        }
        """,
        "variables": {"id": instance_id}
    }, headers=HEADERS)
    
    if response.status_code == 200:
        print(f"Instance {instance_id} successfully shut down.")
    else:
        print(f"Error shutting down instance: {response.text}")

# Deploy an instance
instance_id = create_instance()
if instance_id:
    public_ip = get_instance_status(instance_id)
    print(f"Ollama & Open-WebUI running securely at: https://{DOMAIN_NAME}")
    auto_shutdown(instance_id)
