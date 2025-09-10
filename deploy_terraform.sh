#!/bin/bash

# CloudSQLite Terraform Deployment Script

set -e

echo "🚀 Deploying CloudSQLite with Terraform..."

# Check if Terraform is installed
if ! command -v terraform &> /dev/null; then
    echo "❌ Terraform is not installed. Please install it first."
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "❌ Go is not installed. Please install it first."
    exit 1
fi

# Check AWS credentials
echo "🔐 Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ AWS credentials not configured. Please run 'aws configure' first."
    exit 1
fi

# Initialize Terraform
echo "🔧 Initializing Terraform..."
terraform init

# Plan the deployment
echo "📋 Planning Terraform deployment..."
terraform plan

# Ask for confirmation
read -p "Do you want to apply these changes? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Deployment cancelled."
    exit 1
fi

# Apply the configuration
echo "🚀 Applying Terraform configuration..."
terraform apply -auto-approve

# Get outputs
echo "📊 Getting deployment outputs..."
API_URL=$(terraform output -raw api_gateway_url)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
DYNAMODB_TABLE=$(terraform output -raw dynamodb_table_name)
LAMBDA_ARN=$(terraform output -raw lambda_function_arn)

echo ""
echo "✅ Deployment complete!"
echo "🌐 API URL: $API_URL"
echo "📦 S3 Bucket: $S3_BUCKET"
echo "🗄️ DynamoDB Table: $DYNAMODB_TABLE"
echo "⚡ Lambda ARN: $LAMBDA_ARN"
echo ""
echo "📝 Test the API with:"
echo "curl -X POST $API_URL \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"sql_statement\": \"SELECT 1 as test;\"}'"
echo ""
echo "🎉 CloudSQLite is ready to use!"

# Clean up build artifacts
echo "🧹 Cleaning up build artifacts..."
rm -f lambda/lambda_handler lambda_function.zip

echo "✨ All done!"
