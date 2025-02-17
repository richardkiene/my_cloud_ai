# RunPod Ollama & Open-WebUI Setup

This guide provides step-by-step instructions to deploy **Ollama** and **Open-WebUI** on **RunPod** using their API. This setup includes:

- 🔥 **RunPod GPU instance deployment**
- 🔑 **Secure authentication for WebUI**
- 💾 **Persistent storage for models and data**
- 🔒 **HTTPS with Let's Encrypt SSL**
- 📊 **Usage monitoring and auto-shutdown after inactivity**

---

## Prerequisites

### 1️⃣ Install Required Tools

#### On macOS/Linux

```bash
# Install Python and dependencies
sudo apt update && sudo apt install -y python3 python3-pip
pip install requests
```

#### On Windows

1. Install **Python 3** from [python.org](https://www.python.org/downloads/)
2. Install dependencies:

   ```bash
   pip install requests
   ```

### 2️⃣ Get a RunPod API Key

1. Sign up at [RunPod](https://runpod.io)
2. Go to **API Keys** section
3. Generate a new API key and save it securely

### 3️⃣ Configure Your Domain

1. Ensure you own a domain
2. Update your DNS records to point to the RunPod instance
3. Let's Encrypt will use this domain for SSL

---

## 🚀 Deployment Steps

### 1️⃣ Set Up Environment Variables

Create a `.env` file with the following details:

```bash
RUNPOD_API_KEY="your-runpod-api-key"
DOMAIN_NAME="yourdomain.com"
```

### 2️⃣ Deploy Instance

Run the deployment script:

```bash
python runpod_deploy.py
```

### 3️⃣ Verify Deployment

- Open **<https://yourdomain.com>** in a browser
- Login with the provided authentication

### 4️⃣ Managing Models

SSH into the instance:

```bash
ssh root@yourdomain.com
```

Manage models:

```bash
ollama list      # List available models
ollama pull Llama-3  # Download a new model
ollama rm Llama-3  # Remove a model
```

---

## 🔄 Maintenance & Updates

### 🔹 To Stop the Instance

```bash
python runpod_shutdown.py
```

### 🔹 To Restart the Instance

```bash
python runpod_restart.py
```

### 🔹 To Update SSL Certificate

```bash
ssh root@yourdomain.com "sudo certbot renew --force-renewal"
```

### 🔹 To Destroy Everything

```bash
python runpod_destroy.py
```

---

## 🔒 Security Notes

- Use **strong passwords** for authentication
- **Rotate API keys** regularly
- **Restrict SSH access** to trusted IPs only
- **Monitor usage** to avoid unexpected costs

---

## 💰 Cost Management

- Use **RunPod spot instances** when possible
- Auto-shutdown is enabled after **15 minutes** of inactivity
- Persistent storage minimizes the need for re-downloading models

---

🚀 Your **Ollama & Open-WebUI** instance is now running on **RunPod** with full automation!
