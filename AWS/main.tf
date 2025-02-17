provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  
  filter {
    name   = "architecture"
    values = ["x86_64"]
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

# Spot Instance
resource "aws_spot_instance_request" "ollama" {
  count                = var.use_spot_instance ? 1 : 0
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "g5.xlarge"
  spot_type            = "persistent"
  wait_for_fulfillment = true
  availability_zone    = "${var.aws_region}a"
  key_name            = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.ollama.id]
  user_data           = templatefile("${path.module}/user_data.sh", {
    DOMAIN     = var.custom_domain
    EMAIL      = var.admin_email
    PASSWORD   = var.webui_password
    SNS_TOPIC  = aws_sns_topic.alerts.arn
  })

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name = "ollama-spot"
  }
}

# On-demand Instance
resource "aws_instance" "ollama" {
  count                = var.use_spot_instance ? 0 : 1
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "g5.xlarge"
  availability_zone    = "${var.aws_region}a"
  key_name            = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.ollama.id]
  user_data           = templatefile("${path.module}/user_data.sh", {
    DOMAIN     = var.custom_domain
    EMAIL      = var.admin_email
    PASSWORD   = var.webui_password
    SNS_TOPIC  = aws_sns_topic.alerts.arn
  })

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name = "ollama-ondemand"
  }
}

# Volume Attachment
resource "aws_volume_attachment" "ollama_data_attach" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ollama_data.id
  instance_id = var.use_spot_instance ? aws_spot_instance_request.ollama[0].spot_instance_id : aws_instance.ollama[0].id
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
    InstanceId = var.use_spot_instance ? aws_spot_instance_request.ollama[0].spot_instance_id : aws_instance.ollama[0].id
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
  value = aws_eip.ollama.public_ip
}

output "webui_url" {
  value = "https://${var.custom_domain}"
}