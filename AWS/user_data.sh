#!/bin/bash
set -e

# These variables will be substituted by Terraform
CUSTOM_DOMAIN="${custom_domain}"
ADMIN_EMAIL="${admin_email}"
WEBUI_PASSWORD="${webui_password}"
API_GATEWAY_STATUS_URL="${api_gateway_status_url}"
API_GATEWAY_START_URL="${api_gateway_start_url}"

# Log all output
exec > /var/log/user-data.log 2>&1
echo "Starting user data script at $(date)"

# Export API Gateway URLs for the setup script
export API_GATEWAY_STATUS_URL="$API_GATEWAY_STATUS_URL"
export API_GATEWAY_START_URL="$API_GATEWAY_START_URL"

# Run the setup script with the domain, email, and password
/usr/local/bin/ollama-setup.sh "$CUSTOM_DOMAIN" "$ADMIN_EMAIL" "$WEBUI_PASSWORD"

echo "User data script completed at $(date)"