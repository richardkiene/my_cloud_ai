# Secure Ollama Instance on AWS with Spot Pricing

This Terraform configuration deploys a secure, cost-effective Ollama instance with Open-WebUI on AWS using spot instances. Features include:

- 🔒 Secure HTTPS access with Let's Encrypt
- 💰 Cost-effective spot instance usage
- 🔑 Authentication-protected WebUI
- 📊 Usage monitoring and alerts
- 💾 Persistent storage for models and data
- 🏠 SSH access restricted to home network
- ⏰ Automatic shutdown after 15 minutes of inactivity

## Prerequisites

### 1️⃣ Install Required Tools

#### On macOS

```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install required tools
brew install awscli terraform
```

#### On Ubuntu/Debian

```bash
# Update package list
sudo apt-get update

# Install AWS CLI
sudo apt-get install -y awscli

# Install Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform
```

#### On Windows

1. Install AWS CLI:
   - Download from [AWS CLI Install Guide](https://aws.amazon.com/cli/)
   - Run the installer
   - Verify installation: `aws --version`

2. Install Terraform:
   - Download from [Terraform Downloads](https://www.terraform.io/downloads)
   - Extract to a directory
   - Add to PATH environment variable
   - Verify installation: `terraform --version`

### 2️⃣ Verify Tool Installation

Ensure all tools are properly installed:

```bash
# Check AWS CLI version
aws --version

# Check Terraform version
terraform --version
```

Each command should return a version number. If you get "command not found" errors, check your installation and PATH settings.

### 3️⃣ Setup Your AWS Account

1. Create an AWS account if you don't have one
2. Create an IAM user with programmatic access using one of these two methods:

#### Option A: Using AWS Console

1. Go to IAM → Users → Add User
2. Create a new policy with the following JSON:

   ```json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Effect": "Allow",
               "Action": [
                   "ec2:*",
                   "route53:*",
                   "sns:*",
                   "cloudwatch:*"
               ],
               "Resource": "*"
           },
           {
               "Effect": "Allow",
               "Action": [
                   "iam:CreateRole",
                   "iam:PutRolePolicy",
                   "iam:CreateInstanceProfile",
                   "iam:AddRoleToInstanceProfile",
                   "iam:PassRole",
                   "iam:ListRolePolicies",
                   "iam:GetRole",
                   "iam:GetRolePolicy",
                   "iam:DeleteRole",
                   "iam:DeleteRolePolicy",
                   "iam:RemoveRoleFromInstanceProfile",
                   "iam:DeleteInstanceProfile",
                   "iam:GetInstanceProfile",
                   "iam:ListInstanceProfilesForRole",
                   "iam:ListAttachedRolePolicies",
                   "iam:DetachRolePolicy"
               ],
               "Resource": [
                   "arn:aws:iam::*:role/ollama-instance-role",
                   "arn:aws:iam::*:instance-profile/ollama-instance-profile"
               ]
           }
       ]
   }
   ```

#### Option B: Using AWS CLI

1. Save the above policy to a file named `ollama-policy.json`
2. Create and attach the policy:

   ```bash
   # Create the policy
   aws iam create-policy \
       --policy-name OllamaDeploymentPolicy \
       --policy-document file://ollama-policy.json

   # Create the user
   aws iam create-user --user-name ollama-deployer

   # Attach the policy to the user
   aws iam attach-user-policy \
       --user-name ollama-deployer \
       --policy-arn arn:aws:iam::YOUR_ACCOUNT_ID:policy/OllamaDeploymentPolicy

   # Create access keys
   aws iam create-access-key --user-name ollama-deployer
   ```

3. Save the Access Key ID and Secret Access Key securely

#### Required IAM Permissions Explained

The policy provides the minimum required permissions:

- `ec2:*` - Manage EC2 instances, security groups, and EBS volumes
- `route53:*` - Manage DNS records
- `sns:*` - Create and manage SNS topics for notifications
- `cloudwatch:*` - Set up monitoring and auto-shutdown
- Various `iam:*` permissions:
  - Create and manage the instance role for SNS access
  - Manage instance profiles
  - List and modify role policies
  - These are scoped specifically to the Ollama role and instance profile

### 4️⃣ Configure AWS CLI

```bash
aws configure
```

Enter the following information:

- AWS Access Key ID
- AWS Secret Access Key
- Default region (e.g., us-east-1)
- Default output format (json)

### 5️⃣ Request Spot Instance Quota Increase (Optional)

If you plan to use spot instances (recommended for cost savings):

1. Go to AWS Console → Service Quotas → EC2
2. Search for "All G and VT Spot Instance Requests"
3. Request a quota increase to at least 1 vCPU
4. Wait for AWS approval (typically 1-2 business days)

You can use on-demand instances while waiting for the spot instance quota increase by setting `use_spot_instance = false` in your `terraform.tfvars` file.

### 6️⃣ Set Up Your Domain in Route 53

1. Go to [AWS Route 53](https://console.aws.amazon.com/route53/)
2. Click **Hosted Zones** → **Create Hosted Zone**
3. Enter your domain name (e.g., `yourdomain.com`) and select **Public Hosted Zone**
4. Note the **NS (Name Server) Records** AWS provides
5. Go to your domain registrar (e.g., GoDaddy, Namecheap) and update the **Name Server (NS) Records** with the values from AWS Route 53
6. Wait for DNS propagation (can take up to 48 hours, but usually much faster)

## 🔧 Setup Instructions

### 1️⃣ Configure AWS Secrets Manager

Store your authentication password securely in **AWS Secrets Manager** before deploying:

```bash
aws secretsmanager create-secret --name my-auth-password --secret-string 'SuperSecurePassword123'
```

### 2️⃣ Update `terraform.tfvars` (or pass variables via CLI)

Create a `terraform.tfvars` file with:

```hcl
custom_domain      = "yourdomain.com"
admin_email        = "you@example.com"
key_pair_name      = "your-aws-key"
auth_password_secret = "my-auth-password"
allowed_ssh_ip     = "YOUR.PUBLIC.IP/32"
use_spot_instance  = false  # Set to true after spot instance quota increase
```

### 3️⃣ Initialize Terraform

```bash
terraform init
```

### 4️⃣ Run Terraform Apply

```bash
terraform apply -auto-approve
```

This will create:
✅ **Spot or On-demand Instance (G5 xlarge)**  
✅ **Elastic IP & Route 53 DNS Record**  
✅ **Security Groups and IAM Roles**  
✅ **Ollama & Open-WebUI Installation**  
✅ **SSL Setup & Authentication**

## ✅ Verification

1. **Check Terraform Outputs**

   ```bash
   terraform output
   ```

   Ensure the public IP matches your Route 53 DNS entry.

2. **Verify HTTPS & Open-WebUI**
   - Open `https://yourdomain.com`
   - Login with `admin` and your **configured password**

3. **Check SSL Certificate**

   ```bash
   openssl s_client -connect yourdomain.com:443
   ```

   Ensure it's valid and auto-renewal is enabled.

4. **Check AWS Logs**
   - Open **CloudTrail** → Check API Calls
   - Open **CloudWatch Logs** → Check Instance Auto-Stopping

## 🔄 Maintenance & Updates

### 🔹 To Manually Stop the Instance

```bash
aws ec2 stop-instances --instance-ids INSTANCE_ID
```

### 🔹 To Update Secrets Manager Password

```bash
aws secretsmanager update-secret --secret-id my-auth-password --secret-string 'NewSuperSecurePassword!'
```

### 🔹 To Destroy the Infrastructure

```bash
terraform destroy -auto-approve
```

## 🔒 Security Notes

- **Rotate secrets regularly** using AWS Secrets Manager rotation
- **Limit SSH access** only to your IP (`allowed_ssh_ip`)
- **Monitor logs in CloudTrail** for unauthorized access
- **Review security group rules** periodically

## 🔄 Managing Models

### Adding New Models

1. SSH into your instance:

   ```bash
   ssh ubuntu@yourdomain.com
   ```

2. List available models:

   ```bash
   ollama list
   ```

3. Pull a new model:

   ```bash
   ollama pull mistral
   ```

4. Remove a model:

   ```bash
   ollama rm mistral
   ```

### Model Storage

Models are stored on the persistent EBS volume mounted at `/data/ollama`. This ensures:

- Models survive instance restarts
- Models persist through spot instance replacements
- Storage can be expanded if needed

## 💰 Cost Management

- Use spot instances when possible (`use_spot_instance = true`)
- Instance auto-stops after 15 minutes of inactivity
- Models persist on EBS, so you only pay for storage
- Monitor CloudWatch alerts for usage exceeding 4 hours/day

## 🚀 Future Improvements

🔹 **Enhance with Multi-Factor Authentication (MFA)**  
🔹 **Enable AWS GuardDuty for Threat Detection**  
🔹 **Integrate with AWS Security Hub for automated compliance**
