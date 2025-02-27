# API Gateway for instance control
resource "aws_api_gateway_rest_api" "ollama_api" {
  name        = var.api_gateway_name
  description = "API for controlling Ollama instances"
}

# IAM role for Lambda functions - use the static name from variables
resource "aws_iam_role" "lambda_role" {
  name = var.lambda_role_name
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM policy for Lambda functions
resource "aws_iam_policy" "lambda_policy" {
  name        = "ollama-lambda-policy"
  description = "Policy for Ollama Lambda functions"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:CreateOrUpdateTags",
          "ec2:DescribeInstances",
          "ec2:StartInstances",
          "ec2:DescribeAddresses",
          "ec2:AssociateAddress",
          "ec2:DisassociateAddress",
          "sns:Publish",
          "ssm:PutParameter",
          "ssm:GetParameter"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# IAM role for API Gateway
resource "aws_iam_role" "api_gateway_role" {
  name = "ollama-api-gateway-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

# Policy to allow API Gateway to invoke Lambda
resource "aws_iam_policy" "api_gateway_policy" {
  name        = "ollama-api-gateway-policy"
  description = "Allow API Gateway to invoke Lambda functions"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "api_gateway_policy_attachment" {
  role       = aws_iam_role.api_gateway_role.name
  policy_arn = aws_iam_policy.api_gateway_policy.arn
}

# Lambda function packaging using archive_file
data "archive_file" "start_instance_lambda" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda/start_instance.zip"
  
  source_dir = "${path.module}/lambda/start_instance"
}

data "archive_file" "check_status_lambda" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda/check_status.zip"
  
  source_dir = "${path.module}/lambda/check_status"
}

data "archive_file" "eip_manager_lambda" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda/eip_manager.zip"
  
  source_dir = "${path.module}/lambda/eip_manager"
}

data "archive_file" "update_urls_lambda" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda/update_urls.zip"
  
  source_dir = "${path.module}/lambda/update_urls"
}

# Lambda functions - use static name from variables
resource "aws_lambda_function" "start_instance" {
  function_name    = "ollama-start-instance"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  timeout          = 30
  
  filename         = data.archive_file.start_instance_lambda.output_path
  source_code_hash = data.archive_file.start_instance_lambda.output_base64sha256
  
  environment {
    variables = {
      ASG_NAME = var.asg_name  # Use static name from variables
    }
  }
}

resource "aws_lambda_function" "check_status" {
  function_name    = "ollama-check-status"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler" 
  runtime          = "nodejs18.x"
  timeout          = 30
  
  filename         = data.archive_file.check_status_lambda.output_path
  source_code_hash = data.archive_file.check_status_lambda.output_base64sha256
  
  environment {
    variables = {
      ASG_NAME = var.asg_name  # Use static name from variables
    }
  }
}

resource "aws_lambda_function" "eip_manager" {
  function_name    = "ollama-eip-manager"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  timeout          = 30
  
  filename         = data.archive_file.eip_manager_lambda.output_path
  source_code_hash = data.archive_file.eip_manager_lambda.output_base64sha256
  
  environment {
    variables = {
      EIP_ALLOCATION_ID = aws_eip.ollama.allocation_id
      ASG_NAME          = var.asg_name  # Use static name from variables
      SNS_TOPIC_ARN     = aws_sns_topic.ollama_alerts.arn
    }
  }
}

# Lambda function to update the ASG tags and SSM parameter with API Gateway URL
resource "aws_lambda_function" "update_urls" {
  function_name    = "ollama-update-urls"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  timeout          = 30
  
  filename         = data.archive_file.update_urls_lambda.output_path
  source_code_hash = data.archive_file.update_urls_lambda.output_base64sha256

  environment {
    variables = {
      ASG_NAME        = var.asg_name
      API_GATEWAY_URL = local.api_gateway_invoke_url
      SSM_PARAM_NAME  = aws_ssm_parameter.api_gateway_url_param.name
    }
  }
}

# CloudWatch Events to trigger the EIP Manager Lambda when an instance launches
resource "aws_cloudwatch_event_rule" "instance_launch" {
  name        = "ollama-instance-launch"
  description = "Trigger when an EC2 instance is launched in the Ollama ASG"
  
  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance Launch Successful"]
    detail = {
      AutoScalingGroupName = [var.asg_name]  # Use static name from variables
    }
  })
}

resource "aws_cloudwatch_event_target" "instance_launch_target" {
  rule      = aws_cloudwatch_event_rule.instance_launch.name
  target_id = "OllamaEipManager"
  arn       = aws_lambda_function.eip_manager.arn
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_eip_manager" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.eip_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.instance_launch.arn
}

# API Gateway resource for /start endpoint
resource "aws_api_gateway_resource" "start" {
  rest_api_id = aws_api_gateway_rest_api.ollama_api.id
  parent_id   = aws_api_gateway_rest_api.ollama_api.root_resource_id
  path_part   = "start"
}

# API Gateway method for /start (GET)
resource "aws_api_gateway_method" "start_get" {
  rest_api_id   = aws_api_gateway_rest_api.ollama_api.id
  resource_id   = aws_api_gateway_resource.start.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration with Lambda for /start
resource "aws_api_gateway_integration" "start_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.ollama_api.id
  resource_id             = aws_api_gateway_resource.start.id
  http_method             = aws_api_gateway_method.start_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.start_instance.invoke_arn
}

# API Gateway resource for /status endpoint
resource "aws_api_gateway_resource" "status" {
  rest_api_id = aws_api_gateway_rest_api.ollama_api.id
  parent_id   = aws_api_gateway_rest_api.ollama_api.root_resource_id
  path_part   = "status"
}

# API Gateway method for /status (GET)
resource "aws_api_gateway_method" "status_get" {
  rest_api_id   = aws_api_gateway_rest_api.ollama_api.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration with Lambda for /status
resource "aws_api_gateway_integration" "status_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.ollama_api.id
  resource_id             = aws_api_gateway_resource.status.id
  http_method             = aws_api_gateway_method.status_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.check_status.invoke_arn
}

# Enable CORS for /status
resource "aws_api_gateway_method" "status_options" {
  rest_api_id   = aws_api_gateway_rest_api.ollama_api.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "status_options" {
  rest_api_id = aws_api_gateway_rest_api.ollama_api.id
  resource_id = aws_api_gateway_resource.status.id
  http_method = aws_api_gateway_method.status_options.http_method
  type        = "MOCK"
  
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "status_options_response" {
  rest_api_id = aws_api_gateway_rest_api.ollama_api.id
  resource_id = aws_api_gateway_resource.status.id
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

resource "aws_api_gateway_integration_response" "status_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.ollama_api.id
  resource_id = aws_api_gateway_resource.status.id
  http_method = aws_api_gateway_method.status_options.http_method
  status_code = aws_api_gateway_method_response.status_options_response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# Deploy the API Gateway
resource "aws_api_gateway_deployment" "ollama_api" {
  depends_on = [
    aws_api_gateway_integration.start_lambda,
    aws_api_gateway_integration.status_lambda,
    aws_api_gateway_integration.status_options,
    aws_api_gateway_integration_response.status_options_integration_response
  ]

  rest_api_id = aws_api_gateway_rest_api.ollama_api.id
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.ollama_api.id
  rest_api_id   = aws_api_gateway_rest_api.ollama_api.id
  stage_name    = "prod"
}

locals {
  # This is the proper invoke_url that includes the stage
  api_gateway_invoke_url = "${replace(aws_api_gateway_deployment.ollama_api.invoke_url, "/$/", "")}/${aws_api_gateway_stage.prod.stage_name}"
  
  # URLs for the start and status endpoints
  api_gateway_start_url  = "${local.api_gateway_invoke_url}/start"
  api_gateway_status_url = "${local.api_gateway_invoke_url}/status"
}

# Allow API Gateway to invoke the Lambda functions
resource "aws_lambda_permission" "api_gateway_start" {
  statement_id  = "AllowAPIGatewayToInvokeStartFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_instance.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.ollama_api.execution_arn}/*/${aws_api_gateway_method.start_get.http_method}${aws_api_gateway_resource.start.path}"
}

resource "aws_lambda_permission" "api_gateway_status" {
  statement_id  = "AllowAPIGatewayToInvokeStatusFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check_status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.ollama_api.execution_arn}/*/${aws_api_gateway_method.status_get.http_method}${aws_api_gateway_resource.status.path}"
}

# Run the URL updater Lambda after deployment
resource "null_resource" "invoke_url_updater" {
  depends_on = [
    aws_api_gateway_deployment.ollama_api,
    aws_lambda_function.update_urls
  ]

  # Trigger when the API Gateway URL changes
  triggers = {
    api_url = aws_api_gateway_deployment.ollama_api.invoke_url
  }

  # Invoke the update_urls Lambda
  provisioner "local-exec" {
    command = <<-EOT
      aws lambda invoke \
        --function-name ${aws_lambda_function.update_urls.function_name} \
        --region ${var.aws_region} \
        --payload '{"apiGatewayUrl": "${aws_api_gateway_deployment.ollama_api.invoke_url}"}' \
        /dev/null
    EOT
  }
}

# Output the API Gateway URLs
output "start_url" {
  value       = local.api_gateway_start_url
  description = "URL to start the Ollama instance"
}

output "status_url" {
  value       = local.api_gateway_status_url
  description = "URL to check the Ollama instance status"
}