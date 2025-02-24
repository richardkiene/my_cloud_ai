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

# Use specific AMI created by Packer
data "aws_ami" "ollama" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "image-id"
    values = ["ami-0b87adffd619069e8"]  # Packer-built AMI ID
  }
}

# EBS volume for persistent storage
resource "aws_ebs_volume" "ollama_data" {
  availability_zone = "${var.aws_region}a"
  size              = 100
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "ollama-data"
  }
}

# Spot Instance
resource "aws_spot_instance_request" "ollama" {
  count                  = var.use_spot_instance ? 1 : 0
  ami                    = data.aws_ami.ollama.id
  instance_type          = "g5.xlarge"
  spot_type              = "persistent"
  wait_for_fulfillment   = true
  availability_zone      = aws_ebs_volume.ollama_data.availability_zone
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.ollama.id]
  iam_instance_profile   = aws_iam_instance_profile.ollama_profile.name
  user_data              = templatefile("${path.module}/user_data.sh", {
    custom_domain = var.custom_domain
    admin_email   = var.admin_email
  })

  root_block_device {
    volume_size = 100
    encrypted   = true
  }

  depends_on = [aws_ebs_volume.ollama_data]

  tags = {
    Name = "ollama-spot"
  }
}

# On-demand Instance
resource "aws_instance" "ollama" {
  count                  = var.use_spot_instance ? 0 : 1
  ami                    = data.aws_ami.ollama.id
  instance_type          = "g5.xlarge"
  availability_zone      = aws_ebs_volume.ollama_data.availability_zone
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.ollama.id]
  iam_instance_profile   = aws_iam_instance_profile.ollama_profile.name
  user_data              = templatefile("${path.module}/user_data.sh", {
    custom_domain = var.custom_domain
    admin_email   = var.admin_email
  })

  root_block_device {
    volume_size = 100
    encrypted   = true
  }

  depends_on = [aws_ebs_volume.ollama_data]

  tags = {
    Name = "ollama-ondemand"
  }
}

# Volume Attachment with explicit dependencies
resource "aws_volume_attachment" "ollama_data_attach" {
  device_name  = "/dev/sdh"
  volume_id    = aws_ebs_volume.ollama_data.id
  instance_id  = var.use_spot_instance ? aws_spot_instance_request.ollama[0].spot_instance_id : aws_instance.ollama[0].id
  force_detach = true

  depends_on = [
    aws_spot_instance_request.ollama,
    aws_instance.ollama
  ]
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
    description = "HTTP for certificate validation"
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

# Elastic IP Association
resource "aws_eip_association" "ollama" {
  instance_id   = var.use_spot_instance ? aws_spot_instance_request.ollama[0].spot_instance_id : aws_instance.ollama[0].id
  allocation_id = aws_eip.ollama.id
}

# Route53 Record
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

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "ollama-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

# IAM Role for EC2 Instance
resource "aws_iam_role" "ollama_role" {
  name = "ollama-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ollama_policy" {
  name = "ollama-instance-policy"
  role = aws_iam_role.ollama_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.alerts.arn
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ollama_profile" {
  name = "ollama-instance-profile"
  role = aws_iam_role.ollama_role.name
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

output "instance_id" {
  value       = var.use_spot_instance ? aws_spot_instance_request.ollama[0].spot_instance_id : aws_instance.ollama[0].id
  description = "The ID of the EC2 instance"
}

output "ami_id" {
  value       = data.aws_ami.ollama.id
  description = "The AMI ID being used"
}