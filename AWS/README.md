# Simple and Robust Ollama Deployment on AWS

This Terraform project provides a streamlined, cost-effective Ollama deployment on AWS with the Open-WebUI interface. It focuses on simplicity, reliability, and minimal operational overhead.

## Features

- **Simple, Reliable Infrastructure**: Auto Scaling Group ensures one instance is always maintained
- **Cost Optimization**:
  - Uses spot instances by default with graceful fallback to on-demand
  - Auto-shutdown after 15 minutes of inactivity
  - One-click startup via bookmark
- **Secure Access**:
  - Automatic HTTPS with Let's Encrypt
  - WebUI protected by authentication
  - SSH restricted to your home IP
- **Persistent Storage**: Models stored on EBS volume that persists across instance restarts
- **User-Friendly Interface**: Open-WebUI for easy LLM interaction
- **Minimal Operational Overhead**: Self-healing architecture with auto-recovery

## Architecture

The deployment includes:

- **AWS Deep Learning AMI** with NVIDIA drivers pre-installed
- **Docker containers**: Ollama, Open-WebUI, NGINX, and auto-shutdown monitor
- **Auto Scaling Group** to maintain exactly one instance
- **Elastic IP** automatically associated with the instance
- **API Gateway** and Lambda functions for remote instance management
- **EBS volume** for persistent model storage
- **Route 53** for domain management
- **CloudWatch** and SNS for monitoring and notifications

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **Domain in Route 53** for HTTPS setup (required)
3. **SSH Key Pair** in your AWS account
4. **Terraform** (v1.0.0+) installed on your local machine

## Implementation Details

### Project Structure

The project consists of the following key files:

```bash
ollama-aws/
├── main.tf                       # Main infrastructure resources
├── api-gateway.tf                # API Gateway and Lambda functions
├── variables.tf                  # Variable definitions
├── terraform.tfvars              # Variable values (create this yourself)
├── user_data.sh                  # Instance initialization script
├── lambda/                       # Lambda functions source code
│   ├── start_instance/
│   │   └── index.js              # Lambda function to start instances
│   ├── check_status/
│   │   └── index.js              # Lambda function to check instance status
│   └── eip_manager/
│       └── index.js              # Lambda function to associate Elastic IP
└── scripts/
    └── monitor-activity.sh       # Auto-shutdown monitoring script
```

### Key Components

1. **Auto Scaling Group**: Maintains exactly one instance, handling spot instance provisioning and recovery.

2. **EBS Volume**: 256GB persistent storage for Ollama models, automatically attached to instances.

3. **Lambda Functions**:
   - `start_instance`: Sets ASG desired capacity to 1 to start an instance
   - `check_status`: Retrieves instance status
   - `eip_manager`: Associates Elastic IP with the new instances

4. **API Gateway**: Provides endpoints for starting instances and checking status.

5. **Docker Containers**:
   - Ollama: Runs the LLM with GPU acceleration
   - Open-WebUI: Provides the web interface
   - NGINX: Handles SSL termination and reverse proxy
   - Auto-shutdown monitor: Tracks inactivity and stops the instance

## Quick Start

1. **Clone this repository**

```bash
git clone https://github.com/yourusername/simple-ollama-aws.git
cd simple-ollama-aws
```

2. **Create terraform.tfvars file**

```hcl
aws_region           = "us-east-1"
custom_domain        = "ollama.yourdomain.com"  # Must be in a Route 53 hosted zone
admin_email          = "your.email@example.com"
ssh_key_name         = "your-aws-key-name"
ssh_private_key_path = "~/.ssh/your-private-key.pem"
home_network_cidr    = "1.2.3.4/32"  # Your home IP
webui_password       = "your-secure-password"
use_spot_instance    = true
```

3. **Initialize and apply Terraform**

```bash
terraform init
terraform apply
```

4. **Access Ollama**

- Web UI: `https://your-domain.com`
- Login credentials: username `admin` and the password you specified

## Usage Guide

### Accessing the Web Interface

Once deployment is complete, you can access the Ollama Web UI at `https://your-domain.com` using the credentials:

- Username: `admin`  
- Password: The value you set for `webui_password`

### Starting a Stopped Instance

To save costs, the instance automatically shuts down after 15 minutes of inactivity. To restart it:

1. Open the auto-start URL (provided in Terraform output) or bookmark `https://your-domain.com/ollama-starter.html`
2. Click the "Start Ollama Instance" button
3. Wait 1-2 minutes for the instance to fully initialize

### Model Management

All models are stored on the persistent EBS volume and will survive instance restarts and replacements.

To add new models, use the Open-WebUI interface or connect via SSH:

```bash
ssh ubuntu@your-domain.com
docker exec -it ollama ollama pull llama2
```

## Technical Implementation Notes

### Lambda Function Packaging

The Lambda functions are automatically packaged by Terraform using the `archive_file` data source, which eliminates the need for manual ZIP creation:

```hcl
data "archive_file" "start_instance_lambda" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda/start_instance.zip"
  
  source {
    content  = "... Lambda function code ..."
    filename = "index.js"
  }
}
```

### Auto Scaling Group vs. Manual Spot Management

This solution uses an Auto Scaling Group (ASG) to manage the spot instance lifecycle, which provides several advantages over manual management:

- **Self-healing**: AWS automatically replaces terminated spot instances
- **Simplified code**: No need for complex retry logic across multiple availability zones
- **Better instance lifecycle management**: Graceful termination and replacement

### EBS Volume Attachment

The user data script automatically handles EBS volume attachment, including:

- Detecting the correct device path (including NVMe devices)
- Moving the volume between availability zones if needed
- Creating and mounting the filesystem

### Docker Configuration for GPU Support

For proper GPU support, the Docker daemon is configured with the NVIDIA runtime:

```json
{
    "data-root": "/data/docker",
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
```

### Auto-Shutdown Mechanism

The inactivity monitor container:

1. Monitors activity in Ollama logs and Open-WebUI access
2. Tracks the last activity timestamp
3. After the specified inactivity period (default 15 minutes), issues an EC2 StopInstances API call

## Customization

### Changing Auto-Shutdown Timeout

To modify the inactivity timeout (default 15 minutes):

```hcl
# In terraform.tfvars
inactivity_timeout = 1800  # 30 minutes
```

### Using More Powerful Instances

For larger models, increase the instance size:

```hcl
# In terraform.tfvars
instance_type = "g5.2xlarge"  # 8 vCPUs, 32 GB RAM, 1 NVIDIA A10G GPU
```

### Using On-Demand Instead of Spot

If you prefer reliability over cost savings:

```hcl
# In terraform.tfvars
use_spot_instance = false
```

## Troubleshooting

### Instance Not Starting

Check the CloudWatch logs for the user data script execution:

- Navigate to AWS CloudWatch Logs
- Look for the `/var/log/cloud-init-output.log` log group

You can also check the Lambda function logs:

- Go to AWS Lambda console
- Find the `ollama-start-instance` function
- Check the CloudWatch logs for this function

### SSL Certificate Issues

If the Let's Encrypt certificate isn't working:

1. SSH into the instance
2. Run `docker logs certbot` to check for errors
3. Manually renew with `docker exec -it certbot certbot renew`

### Common Problems and Solutions

| Problem | Solution |
|---------|----------|
| "Ollama taking long to start" | Initial model download can take time - check logs with `docker logs ollama` |
| "Cannot connect to instance" | Make sure your Route 53 DNS has propagated - check with `dig your-domain.com` |
| "Auto-shutdown too aggressive" | Increase `inactivity_timeout` in terraform.tfvars and reapply |
| "Duplicate resource definition" | Make sure resources aren't defined in multiple Terraform files |
| "Lambda packaging error" | Check that the archive_file data source is correctly configured |

## Security Considerations

This deployment includes these security features:

- All traffic encrypted with HTTPS
- SSH access restricted to your home IP
- Authentication required for Web UI
- IAM roles following least privilege principle

## Cost Estimation

With default settings and average usage patterns:

| Component | Est. Monthly Cost |
|-----------|-------------------|
| Spot Instance (G5.xlarge) | $90-150 (with auto-shutdown) |
| EBS Storage (256GB) | $25-30 |
| Data Transfer | $1-5 |
| Route 53 | $0.50 |
| **Total Estimate** | **$120-190/month** |

Costs can be further reduced by:

- Using a smaller instance type for less demanding models
- Reducing EBS volume size
- Being diligent with shutting down when not in use

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
