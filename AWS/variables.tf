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

variable "home_network_cidr" {
  description = "Your home network CIDR for SSH access (e.g., 1.2.3.4/32)"
  type        = string
}

variable "webui_password" {
  description = "Password for WebUI access"
  type        = string
  sensitive   = true
}

variable "use_spot_instance" {
  description = "Whether to use spot instances (true) or on-demand instances (false)"
  type        = bool
  default     = true
}

# Example values file (terraform.tfvars):
# aws_region = "us-east-1"
# custom_domain = "ollama.yourdomain.com"
# admin_email = "you@example.com"
# ssh_key_name = "your-key-name"
# home_network_cidr = "1.2.3.4/32"
# webui_password = "your-secure-password"
# use_spot_instance = true