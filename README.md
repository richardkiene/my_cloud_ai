# Ollama & Open-WebUI Cloud Deployment Automation

This repository provides automation scripts and configurations to deploy **Ollama** and **Open-WebUI** on multiple cloud providers with minimal setup. It includes automated provisioning, security configurations, SSL setup, and cost-saving optimizations.

## 🌎 Supported Cloud Providers

### ✅ AWS

- **Features:**
  - Spot instance usage for cost savings
  - Persistent storage with EBS
  - Secure HTTPS access via Let's Encrypt
  - Auto-shutdown after inactivity
  - Authentication-protected WebUI
- 📖 [AWS Setup Guide](./AWS/README.md)

### ✅ RunPod

- **Features:**
  - Spot and on-demand GPU instances
  - Persistent storage with RunPod Volumes
  - Secure HTTPS via Let's Encrypt
  - Auto-shutdown after inactivity
  - Authentication-protected WebUI
- 📖 [RunPod Setup Guide](./Runpod/README.md)

## 🚀 Getting Started

Choose a cloud provider from the list above and follow the corresponding setup guide to deploy your **Ollama & Open-WebUI** instance.

## 🔧 Future Plans

- Add support for **Lambda Labs, Vast.ai, and Paperspace**
- Improve automation with **Terraform support for all providers**
- Expand cost-saving optimizations for various GPU cloud platforms

## 🛠 Contributions

Feel free to submit **pull requests** to enhance support for additional cloud providers or improve existing setups.

## 📜 License

This repository is licensed under the **GPLv3 License**.
