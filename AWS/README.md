# Secure Ollama Deployment on AWS with Auto-Shutdown

This Terraform configuration deploys a secure, cost-effective Ollama instance with Open-WebUI on AWS using spot or on-demand instances.

## Key Features

- 🔒 **Secure HTTPS access** with automatic Let's Encrypt certificate provisioning
- 💰 **Cost optimization** with spot instances and auto-shutdown after inactivity
- 🚀 **Simplified deployment** using AWS Deep Learning Base AMI with NVIDIA drivers pre-installed
- 🔄 **Multi-AZ availability** with automatic retries for spot capacity
- 💾 **Persistent storage** for models on EBS volume (survives instance restarts)
- 🕸️ **User-friendly interface** with Open-WebUI for Ollama
- 🔑 **Authentication protection** for the WebUI
- 📊 **Usage monitoring** and alerts
- ⏰ **Auto-startup link** for easy instance resumption

## Architecture

This solution deploys:

- **GPU Instance**: AWS G5.xlarge instance (NVIDIA A10G GPU) using the AWS Deep Learning Base AMI
- **Persistent Storage**: 256GB EBS volume for model storage
- **Docker Containers**: Ollama, Open-WebUI, Nginx, and Certbot
- **Networking**: Elastic IP, DNS record in Route 53, and security groups
- **Automation**: Auto-shutdown after 15 minutes of inactivity to save costs
- **API Gateway**: For remote instance startup without AWS console access

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **Domain in Route 53** for HTTPS setup
3. **SSH Key Pair** for instance access
4. **Terraform** installed locally

## Quick Start

1. **Clone this repository**:

   ```bash
   git clone https://github.com/yourusername/secure-ollama-aws.git
   cd secure-ollama-aws
   ```

2. **Create a `terraform.tfvars` file**:

   ```hcl
   aws_region         = "us-east-1"
   custom_domain      = "ollama.yourdomain.com"
   admin_email        = "you@example.com"
   ssh_key_name       = "your-aws-key-name"
   ssh_private_key_path = "~/.ssh/your-private-key.pem"
   home_network_cidr  = "YOUR.HOME.IP.ADDRESS/32"
   webui_password     = "your-secure-password"
   use_spot_instance  = true
   aws_account_id     = "your-aws-account-id"
   ```

3. **Initialize Terraform**:

   ```bash
   terraform init
   ```

4. **Deploy the infrastructure**:

   ```bash
   terraform apply
   ```

5. **Access your Ollama instance**:
   - Open `https://your-domain.com` in your browser
   - Login with username `admin` and the password you specified
   - Start using Ollama with the Open-WebUI interface

## Cost Optimization Features

1. **Spot Instance Support**:
   - Set `use_spot_instance = true` to use spot instances for up to 70% cost savings
   - Automated multi-AZ fallback if spot capacity isn't available

2. **Auto-Shutdown**:
   - Instance automatically shuts down after 15 minutes of inactivity
   - Models remain stored on the persistent EBS volume

3. **One-Click Startup**:
   - Use the provided auto-start URL to restart your instance when needed
   - No need to access the AWS console

## Managing Models

Models are stored on the persistent EBS volume at `/data/ollama/models`, ensuring they survive instance stops/starts and even spot instance replacements.

To manage models:

1. Connect to your instance:

   ```bash
   ssh ubuntu@your-domain.com
   ```

2. Pull a new model:

   ```bash
   docker exec -it ollama ollama pull llama2
   ```

3. List available models:

   ```bash
   docker exec -it ollama ollama list
   ```

## FAQ

**Q: How do I start my stopped instance?**  
A: Use the auto-start URL from the Terraform output or bookmark the page at `https://your-domain.com/ollama-starter.html`.

**Q: Why does my instance shut down automatically?**  
A: The instance shuts down after 15 minutes of inactivity to save costs. Your models are preserved on the persistent storage.

**Q: How do I change the Open-WebUI password?**  
A: Update the `webui_password` variable and run `terraform apply` again.

**Q: Can I use a larger instance type for more powerful models?**  
A: Yes, modify the `instance_type` in `main.tf` to use a more powerful GPU instance like `g5.2xlarge`.

## Customization

- **Auto-Shutdown Timeout**: Change the `INACTIVITY_TIMEOUT` in the `docker-compose.yml` file
- **Different Models**: Pull any model supported by Ollama
- **Instance Size**: Modify the instance type in `main.tf` for larger models

## Security Considerations

- SSH access is restricted to your home network IP address
- WebUI is protected with authentication
- All traffic is encrypted with HTTPS
- Automatic certificate renewal via Let's Encrypt
- IAM roles follow least-privilege principle

## Troubleshooting

**Instance not starting?**

- Check CloudWatch logs under `/var/log/user-data.log`
- Verify the security groups allow HTTP/HTTPS traffic
- Ensure your Route 53 DNS records are correct

**Can't connect after instance starts?**

- The startup process takes 1-2 minutes to complete
- Check that DNS has propagated correctly

## License

This project is licensed under the MIT License - see the LICENSE file for details.
