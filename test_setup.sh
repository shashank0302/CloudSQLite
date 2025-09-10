#!/bin/bash

# CloudSQLite Setup Test Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_color $BLUE "🧪 Testing CloudSQLite Setup..."

# Check if required tools are installed
print_color $YELLOW "📋 Checking prerequisites..."

# Check Go
if command -v go &> /dev/null; then
    GO_VERSION=$(go version | cut -d' ' -f3)
    print_color $GREEN "✅ Go installed: $GO_VERSION"
else
    print_color $RED "❌ Go not installed"
    exit 1
fi

# Check AWS CLI
if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version | cut -d' ' -f1)
    print_color $GREEN "✅ AWS CLI installed: $AWS_VERSION"
else
    print_color $RED "❌ AWS CLI not installed"
    exit 1
fi

# Check Terraform
if command -v terraform &> /dev/null; then
    TERRAFORM_VERSION=$(terraform version -json | jq -r '.terraform_version')
    print_color $GREEN "✅ Terraform installed: $TERRAFORM_VERSION"
else
    print_color $RED "❌ Terraform not installed"
    exit 1
fi

# Check AWS credentials
print_color $YELLOW "🔐 Checking AWS credentials..."
if aws sts get-caller-identity &> /dev/null; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    print_color $GREEN "✅ AWS credentials configured (Account: $ACCOUNT_ID)"
else
    print_color $RED "❌ AWS credentials not configured"
    exit 1
fi

# Test Go modules
print_color $YELLOW "📦 Testing Go modules..."
if [ -f "go.mod" ]; then
    print_color $GREEN "✅ Go module found"
    go mod tidy
    print_color $GREEN "✅ Go dependencies resolved"
else
    print_color $YELLOW "⚠️  No go.mod found, creating one..."
    go mod init cloudsqlite
fi

# Test Lambda module
if [ -f "lambda/go.mod" ]; then
    print_color $GREEN "✅ Lambda Go module found"
    cd lambda
    go mod tidy
    cd ..
    print_color $GREEN "✅ Lambda dependencies resolved"
else
    print_color $YELLOW "⚠️  No lambda/go.mod found"
fi

# Test Terraform configuration
print_color $YELLOW "🏗️  Testing Terraform configuration..."
if [ -f "main.tf" ]; then
    print_color $GREEN "✅ Terraform configuration found"
    terraform init -backend=false
    print_color $GREEN "✅ Terraform initialized"
    terraform validate
    print_color $GREEN "✅ Terraform configuration valid"
else
    print_color $RED "❌ Terraform configuration not found"
    exit 1
fi

# Test load test script
print_color $YELLOW "🧪 Testing load test script..."
if [ -f "run_load_test.sh" ]; then
    print_color $GREEN "✅ Load test script found"
    if [ -x "run_load_test.sh" ]; then
        print_color $GREEN "✅ Load test script is executable"
    else
        print_color $YELLOW "⚠️  Making load test script executable..."
        chmod +x run_load_test.sh
    fi
else
    print_color $RED "❌ Load test script not found"
    exit 1
fi

# Test deployment script
print_color $YELLOW "🚀 Testing deployment script..."
if [ -f "deploy_terraform.sh" ]; then
    print_color $GREEN "✅ Terraform deployment script found"
    if [ -x "deploy_terraform.sh" ]; then
        print_color $GREEN "✅ Deployment script is executable"
    else
        print_color $YELLOW "⚠️  Making deployment script executable..."
        chmod +x deploy_terraform.sh
    fi
else
    print_color $RED "❌ Deployment script not found"
    exit 1
fi

print_color $GREEN "🎉 All tests passed! CloudSQLite is ready for deployment."
print_color $BLUE "📝 Next steps:"
print_color $BLUE "   1. Run: ./deploy_terraform.sh"
print_color $BLUE "   2. Get API URL from Terraform output"
print_color $BLUE "   3. Test with: ./run_load_test.sh -u <API_URL>"
