#main.tf
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

data "aws_ami" "ollama_base" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) *"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  # Basic API Gateway URL components that don't depend on the instances
  api_gateway_id         = aws_api_gateway_rest_api.ec2_control_api.id
  api_gateway_stage_name = "prod"
  api_gateway_url_base   = "${local.api_gateway_id}.execute-api.${var.aws_region}.amazonaws.com/${local.api_gateway_stage_name}"
  api_gateway_start_url  = "https://${local.api_gateway_url_base}/start"
  api_gateway_status_url = "https://${local.api_gateway_url_base}/status"
}

# EBS volume for persistent storage
resource "aws_ebs_volume" "ollama_data" {
  availability_zone = local.spot_instance_az
  size              = 256
  type              = "gp3"
  encrypted         = true

  lifecycle {
    ignore_changes = [availability_zone]
  }

  tags = {
    Name = "ollama-data"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "region-name"
    values = [var.aws_region]
  }
}

# Create a local file containing the HTML content for the external data source to use
resource "local_file" "starting_html" {
  content  = file("${path.module}/templates/starting.html")
  filename = "${path.module}/.terraform/tmp/starting.html"
}

resource "local_file" "starter_html" {
  content  = file("${path.module}/templates/ollama-starter.html")
  filename = "${path.module}/.terraform/tmp/starter_html.html"
}

# Use external data source to gzip content
data "external" "gzip_html" {
  program = ["bash", "${path.module}/compress_html.sh"]

  # The script needs to know the file paths
  query = {
    starting_path = local_file.starting_html.filename
    starter_path  = local_file.starter_html.filename
  }
}

locals {
  # Read HTML templates
  starting_html_content = file("${path.module}/templates/starting.html")
  starter_html_content  = file("${path.module}/templates/ollama-starter.html")

  # Get the compressed content from the external data source
  starting_html_gzip = data.external.gzip_html.result.starting_gzip
  starter_html_gzip  = data.external.gzip_html.result.starter_gzip
}

# Spot Instance
resource "aws_spot_instance_request" "ollama" {
  count                          = var.use_spot_instance ? 1 : 0
  ami                            = data.aws_ami.ollama_base.id
  instance_type                  = "g5.xlarge"
  spot_type                      = "one-time"
  spot_price                     = "0.75"
  wait_for_fulfillment           = false
  availability_zone              = aws_ebs_volume.ollama_data.availability_zone
  key_name                       = var.ssh_key_name
  vpc_security_group_ids         = [aws_security_group.ollama.id]
  iam_instance_profile           = aws_iam_instance_profile.ollama_profile.name
  launch_group                   = "ollama-spot-group"
  instance_interruption_behavior = "terminate"

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [spot_price, availability_zone]
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    CUSTOM_DOMAIN          = var.custom_domain
    ADMIN_EMAIL            = var.admin_email
    WEBUI_PASSWORD         = var.webui_password
    API_GATEWAY_STATUS_URL = local.api_gateway_status_url
    API_GATEWAY_START_URL  = local.api_gateway_start_url
    STARTING_HTML_GZIP     = local.starting_html_gzip
    STARTER_HTML_GZIP      = local.starter_html_gzip
  })

  root_block_device {
    volume_size           = 100
    encrypted             = true
    delete_on_termination = true
  }

  depends_on = [aws_ebs_volume.ollama_data]

  tags = {
    Name                = "ollama-spot"
    ApiGatewayStatusUrl = local.api_gateway_status_url
    ApiGatewayStartUrl  = local.api_gateway_start_url
  }
}

# Create a new null resource to handle trying multiple AZs
resource "null_resource" "try_multiple_az_for_spot" {
  count = var.use_spot_instance ? 1 : 0

  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
# Script to try multiple availability zones for spot capacity

set -e  # Exit on error

# Function to check spot request status
check_spot_request() {
  local request_id=$1
  local status=$(aws ec2 describe-spot-instance-requests \
    --spot-instance-request-ids $request_id \
    --query "SpotInstanceRequests[0].Status.Code" --output text 2>/dev/null || echo "error")
  echo $status
}

# Function to check if an instance is running
check_instance_state() {
  local instance_id=$1
  local state=$(aws ec2 describe-instances \
    --instance-ids $instance_id \
    --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "unknown")
  echo $state
}

# Function to cancel a spot request
cancel_spot_request() {
  local request_id=$1
  aws ec2 cancel-spot-instance-requests --spot-instance-request-ids $request_id 2>/dev/null || true
  echo "Cancelled spot request $request_id"
}

# Function to save state
save_state() {
  local request_id=$1
  local instance_id=$2
  local az=$3
  local state=$4
  
  echo "{\"instance_id\": \"$instance_id\", \"request_id\": \"$request_id\", \"az\": \"$az\", \"state\": \"$state\"}" > ${path.module}/spot_instance_state.json
  echo "Saved state: instance=$instance_id, request=$request_id, az=$az, state=$state"
}

# Function to try a specific AZ
try_az() {
  local az=$1
  echo "Trying availability zone: $az"
  
  # Create new spot request in this AZ
  local new_request=$(aws ec2 request-spot-instances \
    --instance-count 1 \
    --type one-time \
    --spot-price 0.75 \
    --availability-zone $az \
    --launch-specification "{
      \"ImageId\": \"${data.aws_ami.ollama_base.id}\",
      \"InstanceType\": \"g5.xlarge\",
      \"Placement\": {\"AvailabilityZone\": \"$az\"},
      \"KeyName\": \"${var.ssh_key_name}\",
      \"SecurityGroupIds\": [\"${aws_security_group.ollama.id}\"],
      \"IamInstanceProfile\": {\"Name\": \"${aws_iam_instance_profile.ollama_profile.name}\"},
      \"BlockDeviceMappings\": [{
        \"DeviceName\": \"/dev/sda1\",
        \"Ebs\": {
          \"VolumeSize\": 100,
          \"VolumeType\": \"gp3\",
          \"DeleteOnTermination\": true,
          \"Encrypted\": true
        }
      }],
      \"UserData\": \"${base64encode(templatefile("${path.module}/user_data.sh", {
    CUSTOM_DOMAIN          = var.custom_domain
    ADMIN_EMAIL            = var.admin_email
    WEBUI_PASSWORD         = var.webui_password
    API_GATEWAY_STATUS_URL = local.api_gateway_status_url
    API_GATEWAY_START_URL  = local.api_gateway_start_url
    STARTING_HTML_GZIP     = local.starting_html_gzip
    STARTER_HTML_GZIP      = local.starter_html_gzip
}))}\"
    }")
  
  local new_request_id=$(echo $new_request | jq -r '.SpotInstanceRequests[0].SpotInstanceRequestId')
  echo "New request ID: $new_request_id"
  save_state "$new_request_id" "" "$az" "pending"
  
  # Wait for up to 2 minutes for this request to be fulfilled
  for i in {1..12}; do
    sleep 10
    local new_status=$(check_spot_request $new_request_id)
    echo "Status: $new_status"
    
    if [ "$new_status" = "fulfilled" ]; then
      # Success! Get the instance ID
      local instance_id=$(aws ec2 describe-spot-instance-requests \
        --spot-instance-request-ids $new_request_id \
        --query "SpotInstanceRequests[0].InstanceId" --output text)
      echo "Request fulfilled! Instance ID: $instance_id"
      
      # Now check if the instance is actually running
      for j in {1..6}; do
        sleep 10
        local instance_state=$(check_instance_state $instance_id)
        echo "Instance state: $instance_state"
        
        if [ "$instance_state" = "running" ]; then
          # Success! Save state and continue
          echo "Instance is running!"
          
          # Update the EBS volume to be in the correct AZ
          echo "Modifying EBS volume to be in $az"
          aws ec2 modify-volume --volume-id ${aws_ebs_volume.ollama_data.id} --availability-zone $az || true
          
          # Save final state
          save_state "$new_request_id" "$instance_id" "$az" "running"
          return 0
        elif [ "$instance_state" = "terminated" ]; then
          echo "Instance was terminated immediately. Likely capacity issue."
          break
        fi
      done
      
      # If we get here, instance never reached running state
      cancel_spot_request $new_request_id
      return 1
    fi
    
    if [ "$new_status" = "capacity-not-available" ] || [ "$new_status" = "error" ]; then
      # Cancel this request and move on
      cancel_spot_request $new_request_id
      return 1
    fi
  done
  
  # If we got here, this AZ didn't work, cancel request
  cancel_spot_request $new_request_id
  return 1
}

# Initial spot request ID from Terraform
INITIAL_REQUEST_ID="${aws_spot_instance_request.ollama[0].id}"
echo "Initial spot request ID: $INITIAL_REQUEST_ID"
save_state "$INITIAL_REQUEST_ID" "" "${aws_ebs_volume.ollama_data.availability_zone}" "pending"

# Give the initial request some time
sleep 30

# Check initial request status
INITIAL_STATUS=$(check_spot_request $INITIAL_REQUEST_ID)
echo "Initial status: $INITIAL_STATUS"

# If fulfilled, check if the instance is running
if [ "$INITIAL_STATUS" = "fulfilled" ]; then
  # Get the instance ID
  INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --spot-instance-request-ids $INITIAL_REQUEST_ID \
    --query "SpotInstanceRequests[0].InstanceId" --output text)
  echo "Initial request fulfilled! Instance ID: $INSTANCE_ID"
  
  # Check if instance is actually running
  for i in {1..6}; do
    sleep 10
    INSTANCE_STATE=$(check_instance_state $INSTANCE_ID)
    echo "Instance state: $INSTANCE_STATE"
    
    if [ "$INSTANCE_STATE" = "running" ]; then
      echo "Instance is running!"
      save_state "$INITIAL_REQUEST_ID" "$INSTANCE_ID" "${aws_ebs_volume.ollama_data.availability_zone}" "running"
      exit 0
    elif [ "$INSTANCE_STATE" = "terminated" ]; then
      echo "Instance was terminated immediately. Likely capacity issue."
      break
    fi
  done
  
  # If we get here, the instance never reached running state
  cancel_spot_request $INITIAL_REQUEST_ID
else
  # Cancel the initial request
  cancel_spot_request $INITIAL_REQUEST_ID
fi

# Try each AZ in order
for AZ in ${join(" ", var.allowed_azs)}; do
  echo "Trying next AZ: $AZ"
  if try_az $AZ; then
    echo "Success in $AZ"
    exit 0
  fi
  echo "Failed in $AZ, trying next zone"
done

# If we get here, we couldn't get a spot instance in any AZ
echo "Failed to find capacity in any availability zone"
save_state "" "" "${aws_ebs_volume.ollama_data.availability_zone}" "failed"
exit 1
EOT
}

depends_on = [aws_spot_instance_request.ollama, aws_ebs_volume.ollama_data]
}

# Read the state file created by the script
data "local_file" "spot_instance_state" {
  count      = var.use_spot_instance ? 1 : 0
  filename   = "${path.module}/spot_instance_state.json"
  depends_on = [null_resource.try_multiple_az_for_spot]
}

locals {
  default_az = var.allowed_azs[0]

  # State tracking - these will be set by the script and read back
  instance_state_path   = "${path.module}/spot_instance_state.json"
  instance_state_exists = fileexists(local.instance_state_path)

  # More defensive state handling - check if state field exists
  instance_state_raw = local.instance_state_exists ? jsondecode(file(local.instance_state_path)) : { instance_id = "", request_id = "", az = local.default_az }

  # Check if state field exists, and add it if not
  instance_state = merge(
    local.instance_state_raw,
    { state = lookup(local.instance_state_raw, "state", "waiting") }
  )

  # Safe accessors with defaults
  spot_instance_id     = local.instance_state_exists ? local.instance_state.instance_id : ""
  spot_instance_az     = local.instance_state_exists ? local.instance_state.az : local.default_az
  instance_state_value = local.instance_state.state

  # For API Gateway and other resources
  current_instance_id = var.use_spot_instance ? (
    local.spot_instance_id != "" ? local.spot_instance_id : "waiting-for-spot"
    ) : (
    length(aws_instance.ollama) > 0 ? aws_instance.ollama[0].id : "default-instance-id"
  )

  # Determine if we have a valid running instance
  has_valid_instance = var.use_spot_instance ? (
    local.spot_instance_id != "" && local.instance_state_value == "running"
    ) : (
    length(aws_instance.ollama) > 0
  )
}

# On-demand Instance
resource "aws_instance" "ollama" {
  count                  = var.use_spot_instance ? 0 : 1
  ami                    = data.aws_ami.ollama_base.id
  instance_type          = "g5.xlarge"
  availability_zone      = aws_ebs_volume.ollama_data.availability_zone
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.ollama.id]
  iam_instance_profile   = aws_iam_instance_profile.ollama_profile.name

  user_data = templatefile("${path.module}/user_data.sh", {
    CUSTOM_DOMAIN          = var.custom_domain
    ADMIN_EMAIL            = var.admin_email
    WEBUI_PASSWORD         = var.webui_password
    API_GATEWAY_STATUS_URL = local.api_gateway_status_url
    API_GATEWAY_START_URL  = local.api_gateway_start_url
    STARTING_HTML_GZIP     = local.starting_html_gzip
    STARTER_HTML_GZIP      = local.starter_html_gzip
  })

  root_block_device {
    volume_size = 100
    encrypted   = true
  }

  depends_on = [aws_ebs_volume.ollama_data]

  tags = {
    Name                = "ollama-ondemand"
    ApiGatewayStatusUrl = local.api_gateway_status_url
    ApiGatewayStartUrl  = local.api_gateway_start_url
  }

  # Script to ensure instance is fully initialized before volume attachment
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait",
      "echo 'Cloud-init completed'",
      "exit 0"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.ssh_private_key_path)
      host        = self.public_ip
      # Add timeout to avoid indefinite waiting
      timeout = "30m"
    }
  }
}

# Volume Attachment with proper dependency setup
resource "aws_volume_attachment" "ollama_data_attach" {
  count        = local.has_valid_instance ? 1 : 0
  device_name  = "/dev/sdh"
  volume_id    = aws_ebs_volume.ollama_data.id
  instance_id  = var.use_spot_instance ? local.spot_instance_id : aws_instance.ollama[0].id
  force_detach = true

  # Add a provisioner to verify the instance is still running before attempting attachment
  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
# Verify instance is running before attempting attachment
instance_id="${var.use_spot_instance ? local.spot_instance_id : aws_instance.ollama[0].id}"
state=$(aws ec2 describe-instances --instance-ids $instance_id --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "error")
echo "Instance state is: $state"
if [ "$state" != "running" ]; then
  echo "Instance is not running! Current state: $state"
  exit 1
fi
EOT
  }

  depends_on = [
    null_resource.try_multiple_az_for_spot,
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
  count         = local.has_valid_instance ? 1 : 0
  instance_id   = var.use_spot_instance ? local.spot_instance_id : aws_instance.ollama[0].id
  allocation_id = aws_eip.ollama.id

  # Add a provisioner to verify the instance is still running before attempting association
  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
# Verify instance is running before attempting EIP association
instance_id="${var.use_spot_instance ? local.spot_instance_id : aws_instance.ollama[0].id}"
state=$(aws ec2 describe-instances --instance-ids $instance_id --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "error")
echo "Instance state is: $state"
if [ "$state" != "running" ]; then
  echo "Instance is not running! Current state: $state"
  exit 1
fi
EOT
  }

  depends_on = [
    null_resource.try_multiple_az_for_spot,
    aws_spot_instance_request.ollama,
    aws_instance.ollama
  ]
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

# CloudWatch Alarm for excessive running costs
resource "aws_cloudwatch_metric_alarm" "running_time" {
  count               = local.has_valid_instance ? 1 : 0
  alarm_name          = "ollama-running-time-exceeded"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "StatusCheckPassed"
  namespace           = "AWS/EC2"
  period              = "14400" # 4 hours
  statistic           = "SampleCount"
  threshold           = "1" # If instance running for more than 4 hours continuously
  alarm_description   = "This alarm triggers if the Ollama instance runs for more than 4 hours continuously"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = var.use_spot_instance ? local.spot_instance_id : aws_instance.ollama[0].id
  }

  depends_on = [
    null_resource.try_multiple_az_for_spot
  ]
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
          "sns:Publish",
          "ec2:DescribeInstances",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "lambda:InvokeFunction",
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "apigateway:*",
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "secretsmanager:GetSecretValue"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ollama_profile" {
  name = "ollama-instance-profile"
  role = aws_iam_role.ollama_role.name
}

# API Gateway with direct EC2 integration
resource "aws_api_gateway_rest_api" "ec2_control_api" {
  name        = "ollama-control-api"
  description = "API for controlling Ollama EC2 instance"
}

# Resource for starting the instance
resource "aws_api_gateway_resource" "start_resource" {
  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  parent_id   = aws_api_gateway_rest_api.ec2_control_api.root_resource_id
  path_part   = "start"
}

# GET method for the start resource
resource "aws_api_gateway_method" "start_method" {
  rest_api_id   = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id   = aws_api_gateway_resource.start_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration with EC2 StartInstances API
resource "aws_api_gateway_integration" "ec2_start_integration" {
  rest_api_id             = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id             = aws_api_gateway_resource.start_resource.id
  http_method             = aws_api_gateway_method.start_method.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  credentials             = local.api_gateway_role_exists ? "arn:aws:iam::${var.aws_account_id}:role/api-gateway-ec2-control-role" : aws_iam_role.api_gateway_role[0].arn
  uri                     = "arn:aws:apigateway:${var.aws_region}:ec2:action/StartInstances"

  # Transform GET request into EC2 StartInstances request
  request_templates = {
    "application/json" = <<EOF
{
  "InstanceIds": ["${var.use_spot_instance ? "$${stageVariables.spot_instance_id}" : "$${stageVariables.ondemand_instance_id}"}"]
}
EOF
  }
}

# Integration response to redirect to the main domain with starting page
resource "aws_api_gateway_method_response" "start_method_response" {
  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id = aws_api_gateway_resource.start_resource.id
  http_method = aws_api_gateway_method.start_method.http_method
  status_code = "302"

  response_parameters = {
    "method.response.header.Location" = true
  }
}

resource "aws_api_gateway_integration_response" "start_integration_response" {
  depends_on = [aws_api_gateway_integration.ec2_start_integration]

  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id = aws_api_gateway_resource.start_resource.id
  http_method = aws_api_gateway_method.start_method.http_method
  status_code = aws_api_gateway_method_response.start_method_response.status_code

  response_parameters = {
    "method.response.header.Location" = "'https://${var.custom_domain}/starting.html'"
  }

  response_templates = {
    "application/json" = "#set($inputRoot = $input.path('$'))\n{\"message\": \"Instance is being started\"}"
  }
}

# Resource for checking instance status
resource "aws_api_gateway_resource" "status_resource" {
  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  parent_id   = aws_api_gateway_rest_api.ec2_control_api.root_resource_id
  path_part   = "status"
}

# GET method for status resource
resource "aws_api_gateway_method" "status_method" {
  rest_api_id   = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id   = aws_api_gateway_resource.status_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration with EC2 DescribeInstances API
resource "aws_api_gateway_integration" "ec2_status_integration" {
  rest_api_id             = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id             = aws_api_gateway_resource.status_resource.id
  http_method             = aws_api_gateway_method.status_method.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  credentials             = local.api_gateway_role_exists ? "arn:aws:iam::${var.aws_account_id}:role/api-gateway-ec2-control-role" : aws_iam_role.api_gateway_role[0].arn
  uri                     = "arn:aws:apigateway:${var.aws_region}:ec2:action/DescribeInstances"

  request_templates = {
    "application/json" = <<EOF
{
  "InstanceIds": ["${var.use_spot_instance ? "$${stageVariables.spot_instance_id}" : "$${stageVariables.ondemand_instance_id}"}"]
}
EOF
  }
}

# Status method response
resource "aws_api_gateway_method_response" "status_method_response" {
  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id = aws_api_gateway_resource.status_resource.id
  http_method = aws_api_gateway_method.status_method.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

  # Enable CORS
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

# Status integration response
resource "aws_api_gateway_integration_response" "status_integration_response" {
  depends_on = [aws_api_gateway_integration.ec2_status_integration]

  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id = aws_api_gateway_resource.status_resource.id
  http_method = aws_api_gateway_method.status_method.http_method
  status_code = aws_api_gateway_method_response.status_method_response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  response_templates = {
    "application/json" = <<EOF
#set($inputRoot = $input.path('$'))
#if($inputRoot.Reservations.size() == 0)
{
  "status": "not_found",
  "message": "Instance not found"
}
#else
#set($instance = $inputRoot.Reservations[0].Instances[0])
{
  "status": "$instance.State.Name",
  "instanceId": "$instance.InstanceId",
  "instanceType": "$instance.InstanceType",
  "publicIp": "$!instance.PublicIpAddress",
  "launchTime": "$instance.LaunchTime"
}
#end
EOF
  }
}

# CORS options method for status endpoint
resource "aws_api_gateway_method" "status_options" {
  rest_api_id   = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id   = aws_api_gateway_resource.status_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# CORS integration for status endpoint
resource "aws_api_gateway_integration" "status_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id = aws_api_gateway_resource.status_resource.id
  http_method = aws_api_gateway_method.status_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

# CORS options method response
resource "aws_api_gateway_method_response" "status_options_response" {
  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id = aws_api_gateway_resource.status_resource.id
  http_method = aws_api_gateway_method.status_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true
  }

  response_models = {
    "application/json" = "Empty"
  }
}

# CORS options integration response
resource "aws_api_gateway_integration_response" "status_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id
  resource_id = aws_api_gateway_resource.status_resource.id
  http_method = aws_api_gateway_method.status_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# API Gateway deployment
resource "aws_api_gateway_deployment" "ec2_api_deployment" {
  depends_on = [
    aws_api_gateway_integration.ec2_start_integration,
    aws_api_gateway_integration.ec2_status_integration,
    aws_api_gateway_integration_response.start_integration_response,
    aws_api_gateway_integration_response.status_integration_response,
    aws_api_gateway_integration.status_options_integration,
    aws_api_gateway_integration_response.status_options_integration_response,
    aws_api_gateway_method.start_method,
    aws_api_gateway_method.status_method,
    aws_api_gateway_method.status_options
  ]

  rest_api_id = aws_api_gateway_rest_api.ec2_control_api.id

  # Force redeployment when needed
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.start_resource.id,
      aws_api_gateway_method.start_method.id,
      aws_api_gateway_integration.ec2_start_integration.id,
      aws_api_gateway_resource.status_resource.id,
      aws_api_gateway_method.status_method.id,
      aws_api_gateway_integration.ec2_status_integration.id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# API Gateway stage with variables
resource "aws_api_gateway_stage" "ec2_api_stage" {
  deployment_id = aws_api_gateway_deployment.ec2_api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.ec2_control_api.id
  stage_name    = "prod"

  variables = {
    instance_id          = "default-instance-id"
    spot_instance_id     = "default-spot-id"
    ondemand_instance_id = "default-ondemand-id"
  }

  lifecycle {
    ignore_changes = [variables]
  }
}

# Null resource to update API Gateway stage variables after instances are created
resource "null_resource" "update_api_gateway_variables" {
  count = local.has_valid_instance ? 1 : 0

  triggers = {
    instance_id    = var.use_spot_instance ? local.spot_instance_id : (length(aws_instance.ollama) > 0 ? aws_instance.ollama[0].id : "none")
    instance_state = local.instance_state_value
  }

  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
# Verify instance is still running before updating API Gateway
instance_id="${var.use_spot_instance ? local.spot_instance_id : aws_instance.ollama[0].id}"
if [ -n "$instance_id" ] && [ "$instance_id" != "none" ]; then
  state=$(aws ec2 describe-instances --instance-ids $instance_id --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "error")
  echo "Instance state is: $state"
  if [ "$state" != "running" ]; then
    echo "Instance is not running! Current state: $state"
    exit 1
  fi
fi

# Now update API Gateway
aws apigateway update-stage \
  --rest-api-id ${aws_api_gateway_rest_api.ec2_control_api.id} \
  --stage-name prod \
  --patch-operations "op=replace,path=/variables/instance_id,value=${var.use_spot_instance ? local.spot_instance_id : (length(aws_instance.ollama) > 0 ? aws_instance.ollama[0].id : "none")}" \
                     "op=replace,path=/variables/spot_instance_id,value=${var.use_spot_instance ? local.spot_instance_id : "none"}" \
                     "op=replace,path=/variables/ondemand_instance_id,value=${!var.use_spot_instance ? (length(aws_instance.ollama) > 0 ? aws_instance.ollama[0].id : "none") : "none"}"
EOT
  }

  depends_on = [
    aws_api_gateway_stage.ec2_api_stage,
    null_resource.try_multiple_az_for_spot,
    aws_spot_instance_request.ollama,
    aws_instance.ollama
  ]
}

data "aws_iam_roles" "existing_roles" {}

locals {
  api_gateway_role_exists = contains([for role in data.aws_iam_roles.existing_roles.names : role], "api-gateway-ec2-control-role")
}

resource "aws_iam_role" "api_gateway_role" {
  count = local.api_gateway_role_exists ? 0 : 1

  name = "api-gateway-ec2-control-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

locals {
  api_gateway_role_name = local.api_gateway_role_exists ? "api-gateway-ec2-control-role" : aws_iam_role.api_gateway_role[0].name
}

# Use the correct IAM role reference dynamically
locals {
  api_gateway_role = {
    name = "api-gateway-ec2-control-role"
    arn  = local.api_gateway_role_exists ? "arn:aws:iam::${var.aws_account_id}:role/api-gateway-ec2-control-role" : aws_iam_role.api_gateway_role[0].arn
  }
}

# IAM policy for API Gateway role
resource "aws_iam_role_policy" "api_gateway_policy" {
  name = "ec2-control-policy"
  role = local.api_gateway_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole",
          "ec2:StartInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/api-gateway-ec2-control-role"
      }
    ]
  })
}

# Map of AWS regions to their corresponding API Gateway hosted zone IDs
locals {
  api_gateway_hosted_zone_ids = {
    "us-east-1"      = "Z1UJRXOUMOOFQ8"
    "us-east-2"      = "ZOJJZC49E0EPZ"
    "us-west-1"      = "Z2MUQ32089INYE"
    "us-west-2"      = "Z2OJLYMUO9EFXC"
    "af-south-1"     = "Z2DHW2332DAMTN"
    "ap-east-1"      = "Z3FD1VL90ND7K5"
    "ap-south-1"     = "Z3VO1THU9YC4UR"
    "ap-northeast-3" = "Z2YQB5RD63NC85"
    "ap-northeast-2" = "Z20JF4UZKIW1U8"
    "ap-southeast-1" = "ZL327KTPIQFUL"
    "ap-southeast-2" = "Z2RPCDW04V8134"
    "ap-northeast-1" = "Z1YSHQZHG15GKL"
    "ca-central-1"   = "Z19DQILCV0OWEC"
    "eu-central-1"   = "Z1U9ULNL0V5AJ3"
    "eu-west-1"      = "ZLY8HYME6SFDD"
    "eu-west-2"      = "ZJ5UAJN8Y3Z2Q"
    "eu-south-1"     = "Z3ULH7SSC9OV64"
    "eu-west-3"      = "Z3KY65QIEKYHQQ"
    "eu-north-1"     = "Z2OJLYMUO9EFXC"
    "me-south-1"     = "Z2GCCRVQD35TU8"
    "sa-east-1"      = "ZCMLWB8V5SYIT"
  }
}

# Route53 record for the API Gateway
resource "aws_route53_record" "start_endpoint" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "start.${var.custom_domain}"
  type    = "CNAME"
  ttl     = 300

  records = ["${aws_api_gateway_rest_api.ec2_control_api.id}.execute-api.${var.aws_region}.amazonaws.com"]
}

# Update the output for the auto-start and status URLs
output "auto_start_url" {
  value       = local.api_gateway_start_url
  description = "URL to trigger instance auto-start"
}

output "status_url" {
  value       = local.api_gateway_status_url
  description = "URL to check instance status"
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
  value       = local.has_valid_instance ? (var.use_spot_instance ? local.spot_instance_id : aws_instance.ollama[0].id) : "no-instance-yet"
  description = "The ID of the EC2 instance"
}

output "instance_state" {
  value       = local.instance_state_value
  description = "Current state of the spot instance creation process"
}

output "ami_id" {
  value       = data.aws_ami.ollama_base.id
  description = "The AMI ID being used"
}