provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "custom_domain" {
  description = "Your custom domain name"
  type        = string
}

variable "admin_email" {
  description = "Admin email for SSL certificates"
  type        = string
}

variable "ssh_key_name" {
  description = "Name of SSH key pair to use"
  type        = string
}

variable "home_network_cidr" {
  description = "Your home network CIDR for SSH access"
  type        = string
}

variable "webui_password" {
  description = "Password for WebUI access"
  type        = string
  sensitive   = true
}

# Data sources
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# EBS volume for persistent storage
resource "aws_ebs_volume" "ollama_data" {
  availability_zone = "${var.aws_region}a"
  size             = 50
  type             = "gp3"
  encrypted        = true

  tags = {
    Name = "ollama-data"
  }
}

# Spot Instance Request
resource "aws_spot_instance_request" "ollama" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type         = "g5.xlarge"
  spot_type             = "persistent"
  wait_for_fulfillment  = true
  availability_zone     = "${var.aws_region}a"
  key_name             = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.ollama.id]
  user_data            = templatefile("${path.module}/user_data.sh", {
    DOMAIN     = var.custom_domain
    EMAIL      = var.admin_email
    PASSWORD   = var.webui_password
  })

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name = "ollama-spot"
  }
}

# Volume Attachment
resource "aws_volume_attachment" "ollama_data_attach" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ollama_data.id
  instance_id = aws_spot_instance_request.ollama.spot_instance_id
}

# Security Group
resource "aws_security_group" "ollama" {
  name        = "ollama-sg"
  description = "Security group for Ollama instance"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.home_network_cidr]
    description = "SSH from home network"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from anywhere"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP for Let's Encrypt validation"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Elastic IP
resource "aws_eip" "ollama" {
  domain = "vpc"
  tags = {
    Name = "ollama-eip"
  }
}

resource "aws_eip_association" "ollama" {
  instance_id   = aws_spot_instance_request.ollama.spot_instance_id
  allocation_id = aws_eip.ollama.id
}

# Route53 Record
data "aws_route53_zone" "domain" {
  name = var.custom_domain
  private_zone = false
}

resource "aws_route53_record" "ollama" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = var.custom_domain
  type    = "A"
  ttl     = "300"
  records = [aws_eip.ollama.public_ip]
}

# CloudWatch for monitoring and auto-shutdown
resource "aws_cloudwatch_metric_alarm" "usage_alert" {
  alarm_name          = "ollama-daily-usage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "86400"
  statistic           = "SampleCount"
  threshold           = "14400"
  alarm_description   = "This metric monitors daily instance usage"
  alarm_actions      = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_spot_instance_request.ollama.spot_instance_id
  }
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "ollama-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

# Outputs
output "instance_ip" {
  value = aws_eip.ollama.public_ip
}

output "webui_url" {
  value = "https://${var.custom_domain}"
}