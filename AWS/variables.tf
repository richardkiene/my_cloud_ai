variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "custom_domain" {
  description = "Custom domain for the Ollama instance (must be configured in Route 53)"
  type        = string
}

variable "admin_email" {
  description = "Admin email for Let's Encrypt and notifications"
  type        = string
}

variable "ssh_key_name" {
  description = "Name of the SSH key pair to use for instance access"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key file for initial provisioning"
  type        = string
}

variable "home_network_cidr" {
  description = "Your home network CIDR for SSH access (e.g. 1.2.3.4/32)"
  type        = string
}

variable "webui_password" {
  description = "Password for WebUI authentication (username is 'admin')"
  type        = string
  sensitive   = true
}

variable "use_spot_instance" {
  description = "Whether to use spot instances (true) or on-demand instances (false)"
  type        = bool
  default     = true
}

variable "spot_max_price" {
  description = "Maximum price per hour for spot instances"
  type        = string
  default     = "1.00"
}

variable "instance_type" {
  description = "Instance type to use"
  type        = string
  default     = "g5.xlarge"
}

variable "root_volume_size" {
  description = "Size of the root volume in GB"
  type        = number
  default     = 100
}

variable "model_volume_size" {
  description = "Size of the EBS volume for model storage in GB"
  type        = number
  default     = 256
}

variable "inactivity_timeout" {
  description = "Time in seconds before auto-shutdown due to inactivity"
  type        = number
  default     = 900  # 15 minutes
}

# Static resource names to avoid circular references
variable "asg_name" {
  description = "Name of the Auto Scaling Group"
  type        = string
  default     = "ollama-asg"
}

variable "lambda_role_name" {
  description = "Name of the IAM role for Lambda functions"
  type        = string
  default     = "ollama-lambda-role"
}

variable "sns_topic_name" {
  description = "Name of the SNS topic for alerts"
  type        = string
  default     = "ollama-alerts"
}

variable "api_gateway_name" {
  description = "Name of the API Gateway"
  type        = string
  default     = "ollama-control-api"
}