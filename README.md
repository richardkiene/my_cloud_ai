# Secure Ollama Instance on AWS with Spot Pricing

This Terraform configuration deploys a secure, cost-effective Ollama instance with Open-WebUI on AWS using spot instances. Features include:

- 🔒 Secure HTTPS access with Let's Encrypt
- 💰 Cost-effective spot instance usage
- 🔑 Authentication-protected WebUI
- 📊 Usage monitoring and alerts
- 💾 Persistent storage for models and data
- 🏠 SSH access restricted to home network
- ⏰ Automatic shutdown after 15 minutes of inactivity

## Prerequisites

### 1. AWS Account Setup

1. Create an AWS account if you don't have one
2. Create an IAM user with programmatic access and the following permissions:
   - AmazonEC2FullAccess
   - AmazonRoute53FullAccess
   - AmazonSNSFullAccess
   - CloudWatchFullAccess
3. Save the Access Key ID and Secret Access Key

### 2. Local Tools Installation

#### On macOS:
```bash
brew install awscli terraform
```

#### On Ubuntu/Debian:
```bash
sudo apt-get update
sudo apt-get install -y awscli
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install terraform
```

### 3. AWS CLI Configuration

```bash
aws configure
```
Enter your AWS credentials and preferred region when prompted.

### 4. Domain Setup

1. In Namecheap:
   - Go to your domain's DNS settings
   - Add/update nameservers to use AWS nameservers (will be provided after creating Route53 hosted zone)

2. In AWS Route53:
   - Create a hosted zone for your domain
   - Note the nameservers and update them in Namecheap
   - Wait for DNS propagation (can take up to 48 hours)

## Installation

1. Clone this repository:
```bash
git clone [repository-url]
cd [repository-name]
```

2. Create a `terraform.tfvars` file:
```hcl
aws_region = "us-east-1"
custom_domain = "your-domain.com"
admin_email = "your-email@example.com"
ssh_key_name = "your-aws-ssh-key"
home_network_cidr = "your-home-ip/32"
webui_password = "your-secure-password"
```

3. Initialize Terraform:
```bash
terraform init
```

4. Apply the configuration:
```bash
terraform apply
```

## Validation

1. Check the outputs:
```bash
terraform output
```

2. Verify HTTPS access:
   - Open your domain in a browser
   - You should see a login prompt
   - Login with username "admin" and your configured password

3. Test SSH access:
```bash
ssh ubuntu@your-domain.com
```

4. Verify auto-shutdown:
   - Leave the instance idle for 15 minutes
   - It should automatically shut down
   - Access the WebUI again to automatically restart it

## Usage

### Accessing the WebUI

1. Visit `https://your-domain.com`
2. Login with:
   - Username: admin
   - Password: (the one you set in terraform.tfvars)

### Managing Models

### Updating the Instance

1. SSH into the instance:
```bash
ssh ubuntu@your-domain.com
```

2. Update system packages:
```bash
sudo apt update && sudo apt upgrade -y
```

3. Update Ollama:
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

4. Update Open-WebUI:
```bash
sudo docker pull ghcr.io/open-webui/open-webui:main
sudo docker rm -f open-webui
sudo docker run -d \
    --name open-webui \
    --restart unless-stopped \
    -v /data/open-webui:/root/.cache \
    -p 3000:8080 \
    -e OLLAMA_API_BASE_URL=http://host.docker.internal:11434/api \
    --add-host host.docker.internal:host-gateway \
    ghcr.io/open-webui/open-webui:main
```

### Backing Up Data

Your models and conversation history are automatically persisted on the EBS volume. However, you can create additional backups:

1. Create an EBS snapshot:
```bash
aws ec2 create-snapshot \
    --volume-id $(aws ec2 describe-volumes --filters "Name=tag:Name,Values=ollama-data" --query 'Volumes[0].VolumeId' --output text) \
    --description "Ollama data backup $(date +%Y-%m-%d)"
```

2. Export conversation history:
```bash
sudo tar -czf ollama-backup.tar.gz /data/open-webui
```

### Troubleshooting

#### Instance Not Starting
1. Check the spot instance status:
```bash
aws ec2 describe-spot-instance-requests --filters "Name=tag:Name,Values=ollama-spot"
```

2. Check CloudWatch logs for errors:
```bash
aws logs get-log-events --log-group-name /aws/ec2/ollama --log-stream-name $(date +%Y/%m/%d)
```

#### WebUI Not Accessible
1. Check Nginx status:
```bash
sudo systemctl status nginx
```

2. Check Nginx logs:
```bash
sudo tail -f /var/log/nginx/error.log
```

3. Check Docker container status:
```bash
sudo docker ps
sudo docker logs open-webui
```

#### SSL Certificate Issues
1. Manual certificate renewal:
```bash
sudo certbot renew --force-renewal
sudo systemctl restart nginx
```

2. Check certificate status:
```bash
sudo certbot certificates
```

### Security Best Practices

1. Regularly update the WebUI password:
   - Edit `/etc/nginx/.htpasswd`
   - Run: `sudo htpasswd -c /etc/nginx/.htpasswd admin`

2. Keep your home IP address updated:
   - Update `home_network_cidr` in terraform.tfvars
   - Run: `terraform apply`

3. Monitor AWS CloudTrail for suspicious activity

4. Regularly rotate SSH keys:
   - Generate new key pair in AWS
   - Update `ssh_key_name` in terraform.tfvars
   - Run: `terraform apply`

## Cost Management

The configuration uses several strategies to minimize costs:

1. **Spot Instances**: Reduces compute costs by up to 90%
2. **Auto-shutdown**: Prevents unnecessary running costs
3. **GP3 EBS**: Cost-effective storage for models
4. **CloudWatch Monitoring**: Alerts for excessive usage

To estimate costs:
1. G5.xlarge spot instance: ~$0.15-0.30/hour (varies by region)
2. EBS storage: ~$0.08/GB/month
3. Data transfer: First 1GB free, then $0.09/GB
4. Route53: $0.50/hosted zone/month

## Cleanup

To destroy all resources:

```bash
# Backup data if needed
aws ec2 create-snapshot \
    --volume-id $(aws ec2 describe-volumes --filters "Name=tag:Name,Values=ollama-data" --query 'Volumes[0].VolumeId' --output text) \
    --description "Final backup before teardown"

# Destroy infrastructure
terraform destroy
```

### Monitoring Usage

- Check CloudWatch for usage metrics
- You'll receive email alerts when:
  - Instance starts up
  - Daily usage exceeds 4 hours
  - Instance shuts down due to inactivity

## Maintenance

### Updating the Instance

1. SSH into the instance
```bash
ssh ubuntu@your-domain.com
```

2. List available models:
```bash
ollama list
```

3. Pull a new model:
```bash
ollama pull mistral
```

4. Remove a model:
```bash
ollama rm mistral
```

## Contributing

Feel free to submit issues and enhancement requests!: