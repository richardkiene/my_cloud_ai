terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}

# Get the latest Deep Learning AMI with NVIDIA drivers
data "aws_ami" "ollama_base" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Get the current account ID for policies
data "aws_caller_identity" "current" {}

# Get available availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  
  # These placeholders will be replaced at runtime by the instance
  api_gateway_placeholder = "https://PLACEHOLDER_API_GATEWAY"
  start_url_placeholder   = "${local.api_gateway_placeholder}/start"
  status_url_placeholder  = "${local.api_gateway_placeholder}/status"
}

# Persistent EBS volume for models 
resource "aws_ebs_volume" "ollama_data" {
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = var.model_volume_size
  type              = "gp3"
  encrypted         = true
  
  tags = {
    Name = "ollama-model-storage"
  }
}

# Security Group 
resource "aws_security_group" "ollama" {
  name        = "ollama-sg"
  description = "Allow access to Ollama deployment"

  # SSH only from admin IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.home_network_cidr]
    description = "SSH from admin IP"
  }

  # HTTP for Let's Encrypt validation
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP for certificate validation"
  }

  # HTTPS for web UI
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS for WebUI"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ollama-security-group"
  }
}

# IAM Role for EC2 Instance
resource "aws_iam_role" "ollama_instance_role" {
  name = "ollama-instance-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# IAM Policy for EC2 Instance
resource "aws_iam_policy" "ollama_instance_policy" {
  name        = "ollama-instance-policy"
  description = "Policy for Ollama instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StopInstances",
          "ec2:DescribeVolumes",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DescribeTags",
          "sns:Publish",
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "ollama_policy_attachment" {
  role       = aws_iam_role.ollama_instance_role.name
  policy_arn = aws_iam_policy.ollama_instance_policy.arn
}

# Create instance profile
resource "aws_iam_instance_profile" "ollama_profile" {
  name = "ollama-instance-profile"
  role = aws_iam_role.ollama_instance_role.name
}

# SNS Topic for alerts
resource "aws_sns_topic" "ollama_alerts" {
  name = var.sns_topic_name
  
  tags = {
    Name = "ollama-alerts"
  }
}

# Subscribe admin email to alerts
resource "aws_sns_topic_subscription" "admin_email" {
  topic_arn = aws_sns_topic.ollama_alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

# Store API Gateway URLs in SSM Parameters for runtime retrieval
resource "aws_ssm_parameter" "api_gateway_url_param" {
  name  = "/ollama/api-gateway-url"
  type  = "String"
  value = "WILL_BE_UPDATED_LATER"  # This will be updated by a Lambda after deployment
  
  lifecycle {
    ignore_changes = [value]
  }
}

# Launch Template for EC2 instances
resource "aws_launch_template" "ollama" {
  name                   = "ollama-launch-template"
  image_id               = data.aws_ami.ollama_base.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.ollama.id]
  
  # Use a simpler user data script that avoids template interpolation issues
  user_data = base64encode(<<-EOT
#!/bin/bash
set -e

# Configuration values from Terraform
export CUSTOM_DOMAIN="${var.custom_domain}"
export ADMIN_EMAIL="${var.admin_email}"
export WEBUI_PASSWORD="${var.webui_password}"
export API_GATEWAY_STATUS_URL="${local.status_url_placeholder}"
export API_GATEWAY_START_URL="${local.start_url_placeholder}"
export VOLUME_ID="${aws_ebs_volume.ollama_data.id}"
export SNS_TOPIC_ARN="${aws_sns_topic.ollama_alerts.arn}"
export SSM_PARAM_URL="${aws_ssm_parameter.api_gateway_url_param.name}"

# Set up logging
exec > >(tee /var/log/user-data.log) 2>&1
echo "Starting Ollama setup at $(date)"

# Download the setup script from our S3 bucket
mkdir -p /tmp/ollama-setup
cd /tmp/ollama-setup
echo "Downloading setup script from S3..."
aws s3 cp s3://${aws_s3_bucket.setup_scripts.bucket}/setup.sh setup.sh
chmod +x setup.sh

# Execute the script with our environment variables
./setup.sh

echo "Setup completed successfully!"
EOT
  )
  
  # Rest of the launch template configuration remains the same...
  iam_instance_profile {
    name = aws_iam_instance_profile.ollama_profile.name
  }
  
  block_device_mappings {
    device_name = "/dev/sda1"
    
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }
  
  # Request spot instances if configured
  dynamic "instance_market_options" {
    for_each = var.use_spot_instance ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price = var.spot_max_price
      }
    }
  }
  
  tag_specifications {
    resource_type = "instance"
    
    tags = {
      Name = "ollama-instance"
    }
  }
  
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}

# Auto Scaling Group to maintain one instance
resource "aws_autoscaling_group" "ollama" {
  name                = var.asg_name
  desired_capacity    = 1
  min_size            = 0
  max_size            = 1
  vpc_zone_identifier = [aws_default_subnet.primary.id]
  
  # Use launch template for instance configuration
  launch_template {
    id      = aws_launch_template.ollama.id
    version = "$Latest"
  }
  
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }
 
  # CloudWatch metric for auto-shutdown
  metrics_granularity = "1Minute"
  enabled_metrics     = ["GroupInServiceInstances"]
  
  # Important: allow model downloads to complete before terminating
  termination_policies = ["OldestInstance"]
  
  tag {
    key                 = "Name"
    value               = "ollama-asg-instance"
    propagate_at_launch = true
  }
  
  dynamic "tag" {
    for_each = {
      "ApiGatewayUrl"      = local.api_gateway_placeholder
      "ApiGatewayStartUrl" = local.start_url_placeholder
      "ApiGatewayStatusUrl" = local.status_url_placeholder
    }
    
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
  
  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      tag # Ignore changes to the API Gateway URL tags which will be updated later
    ]
  }
}

# Default subnet in the first AZ
resource "aws_default_subnet" "primary" {
  availability_zone = data.aws_availability_zones.available.names[0]
}

# Use Elastic IP with auto-reassociation 
resource "aws_eip" "ollama" {
  domain = "vpc"
  
  tags = {
    Name = "ollama-eip"
  }
}

# Route53 DNS record
data "aws_route53_zone" "domain" {
  name         = var.custom_domain
  private_zone = false
}

resource "aws_route53_record" "ollama" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = var.custom_domain
  type    = "A"
  ttl     = "300"
  records = [aws_eip.ollama.public_ip]
}

resource "aws_s3_bucket" "setup_scripts" {
  bucket = "ollama-setup-scripts-${local.account_id}" # Using account ID for uniqueness
  
  tags = {
    Name = "Ollama Setup Scripts"
  }
}

# Block all public access by default
resource "aws_s3_bucket_public_access_block" "setup_scripts" {
  bucket                  = aws_s3_bucket.setup_scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload the setup script to S3
resource "aws_s3_object" "setup_script" {
  bucket = aws_s3_bucket.setup_scripts.id
  key    = "setup.sh"
  source = "${path.module}/setup.sh" # Path to the setup.sh file
  etag   = filemd5("${path.module}/setup.sh")
  
  # Ensure proper content type to prevent download issues
  content_type = "text/x-shellscript"
}

# Policy to let the EC2 instance download the setup script
resource "aws_iam_policy" "setup_script_access" {
  name        = "ollama-setup-script-access"
  description = "Allow EC2 instances to download setup scripts from S3"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.setup_scripts.arn}/setup.sh"
      }
    ]
  })
}

# Attach the policy to the EC2 instance role
resource "aws_iam_role_policy_attachment" "setup_script_attachment" {
  role       = aws_iam_role.ollama_instance_role.name
  policy_arn = aws_iam_policy.setup_script_access.arn
}

# Outputs
output "instance_ip" {
  value       = aws_eip.ollama.public_ip
  description = "The public IP address of the Ollama instance"
}

output "webui_url" {
  value       = "https://${var.custom_domain}"
  description = "The URL to access the Open WebUI"
}