#!/bin/bash
set -e

# These variables will be substituted by Terraform
CUSTOM_DOMAIN="${custom_domain}"
ADMIN_EMAIL="${admin_email}"

# Log all output
exec > /var/log/user-data.log 2>&1
echo "Starting user data script at $(date)"

# Run the setup script with the domain and email
/usr/local/bin/ollama-setup.sh "$CUSTOM_DOMAIN" "$ADMIN_EMAIL"

echo "User data script completed at $(date)"