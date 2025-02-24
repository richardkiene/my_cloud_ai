packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  type    = string
  default = ""
  description = "VPC ID to use (leave empty to use default VPC)"
}

variable "subnet_id" {
  type    = string
  default = ""
  description = "Subnet ID to use (leave empty to use default subnet in the default VPC)"
}

source "amazon-ebs" "ollama" {
  ami_name      = "ollama-gpu-base-{{timestamp}}"
  instance_type = "t3.medium"  # Smaller, cheaper instance for AMI creation
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      virtualization-type = "hvm"
      architecture        = "x86_64"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  ssh_username = "ubuntu"
  
  # Use default VPC and subnet
  vpc_id                   = "${var.vpc_id}"
  subnet_id                = "${var.subnet_id}"
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]
  
  # Set a larger root volume
  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 25
    volume_type = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "ollama-gpu-base"
    Environment = "production"
    Builder     = "packer"
  }
}

build {
  name    = "ollama-ami"
  sources = ["source.amazon-ebs.ollama"]

  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait"
    ]
  }

  provisioner "shell" {
    script = "setup.sh"
  }

  provisioner "file" {
    source      = "docker-compose.yml"
    destination = "/home/ubuntu/docker-compose.yml"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /data",
      "sudo mv /home/ubuntu/docker-compose.yml /data/docker-compose.yml",
      "sudo chown root:root /data/docker-compose.yml"
    ]
  }
}