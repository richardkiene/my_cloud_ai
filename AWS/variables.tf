#variables.tf
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "custom_domain" {
  description = "Your custom domain name"
  type        = string
}

variable "admin_email" {
  description = "Admin email for SSL certificates and notifications"
  type        = string
}

variable "ssh_key_name" {
  description = "Name of SSH key pair to use"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key file for provisioning"
  type        = string
}

variable "home_network_cidr" {
  description = "Your home network CIDR for SSH access (e.g., 1.2.3.4/32)"
  type        = string
}

variable "webui_password" {
  description = "Password for WebUI authentication"
  type        = string
  sensitive   = true
}

variable "use_spot_instance" {
  description = "Whether to use spot instances (true) or on-demand instances (false)"
  type        = bool
  default     = true
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
  sensitive   = true
}

variable "allowed_azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
}

# Example values file (terraform.tfvars):
# aws_region = "us-east-1"
# custom_domain = "ollama.yourdomain.com"
# admin_email = "you@example.com"
# ssh_key_name = "your-key-name"
# ssh_private_key_path = "~/.ssh/your-key.pem"
# home_network_cidr = "1.2.3.4/32"
# webui_password_secret = "ollama/webui-password"
# use_spot_instance = true