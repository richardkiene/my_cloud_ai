#!/bin/bash
# Script to compress HTML files for Terraform external data source

# Read input from Terraform
eval "$(jq -r '@sh "STARTING_PATH=\(.starting_path) STARTER_PATH=\(.starter_path)"')"

# Compress the HTML files
STARTING_GZIP=$(cat "$STARTING_PATH" | gzip -9 | base64)
STARTER_GZIP=$(cat "$STARTER_PATH" | gzip -9 | base64)

# Output the result in JSON format for Terraform to read
jq -n \
  --arg starting_gzip "$STARTING_GZIP" \
  --arg starter_gzip "$STARTER_GZIP" \
  '{"starting_gzip": $starting_gzip, "starter_gzip": $starter_gzip}'