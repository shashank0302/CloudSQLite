#!/bin/bash

# CloudSQLite AWS Lambda Deployment Script

set -e

# Configuration
FUNCTION_NAME="cloudsqlite-lambda"
REGION="us-east-1"
S3_BUCKET="cloudsqlite-databases"
DYNAMODB_TABLE="CloudSQLite-Locks"

echo "🚀 Deploying CloudSQLite Lambda Function..."

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

# Create S3 bucket if it doesn't exist
echo "📦 Creating S3 bucket..."
aws s3 mb s3://$S3_BUCKET --region $REGION 2>/dev/null || echo "Bucket already exists"

# Create DynamoDB table if it doesn't exist
echo "🗄️ Creating DynamoDB table..."
aws dynamodb create-table \
    --table-name $DYNAMODB_TABLE \
    --attribute-definitions \
        AttributeName=database_name,AttributeType=S \
    --key-schema \
        AttributeName=database_name,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region $REGION 2>/dev/null || echo "Table already exists"

# Wait for table to be active
echo "⏳ Waiting for DynamoDB table to be active..."
aws dynamodb wait table-exists --table-name $DYNAMODB_TABLE --region $REGION

# Build the Lambda function
echo "🔨 Building Lambda function..."
cd lambda
GOOS=linux GOARCH=amd64 go build -o lambda_handler main.go
cd ..

# Create deployment package
echo "📦 Creating deployment package..."
zip lambda_function.zip lambda/lambda_handler

# Deploy Lambda function
echo "🚀 Deploying Lambda function..."
aws lambda create-function \
    --function-name $FUNCTION_NAME \
    --runtime go1.x \
    --role arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/lambda-execution-role \
    --handler lambda_handler \
    --zip-file fileb://lambda_function.zip \
    --region $REGION 2>/dev/null || \
aws lambda update-function-code \
    --function-name $FUNCTION_NAME \
    --zip-file fileb://lambda_function.zip \
    --region $REGION

# Create API Gateway
echo "🌐 Creating API Gateway..."
API_ID=$(aws apigateway create-rest-api \
    --name "cloudsqlite-api" \
    --description "CloudSQLite API" \
    --region $REGION \
    --query 'id' \
    --output text 2>/dev/null || \
aws apigateway get-rest-apis \
    --region $REGION \
    --query 'items[?name==`cloudsqlite-api`].id' \
    --output text)

# Get root resource ID
ROOT_ID=$(aws apigateway get-resources \
    --rest-api-id $API_ID \
    --region $REGION \
    --query 'items[?path==`/`].id' \
    --output text)

# Create /sql resource
RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id $API_ID \
    --parent-id $ROOT_ID \
    --path-part sql \
    --region $REGION \
    --query 'id' \
    --output text 2>/dev/null || \
aws apigateway get-resources \
    --rest-api-id $API_ID \
    --region $REGION \
    --query 'items[?pathPart==`sql`].id' \
    --output text)

# Create POST method
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $RESOURCE_ID \
    --http-method POST \
    --authorization-type NONE \
    --region $REGION 2>/dev/null || echo "Method already exists"

# Set up Lambda integration
aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $RESOURCE_ID \
    --http-method POST \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$REGION:$(aws sts get-caller-identity --query Account --output text):function:$FUNCTION_NAME/invocations \
    --region $REGION 2>/dev/null || echo "Integration already exists"

# Deploy API
echo "🚀 Deploying API Gateway..."
aws apigateway create-deployment \
    --rest-api-id $API_ID \
    --stage-name prod \
    --region $REGION 2>/dev/null || echo "Deployment already exists"

# Get API URL
API_URL="https://$API_ID.execute-api.$REGION.amazonaws.com/prod/sql"
echo "✅ Deployment complete!"
echo "🌐 API URL: $API_URL"
echo ""
echo "📝 Test the API with:"
echo "curl -X POST $API_URL \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"sql_statement\": \"SELECT * FROM logs;\"}'"

# Clean up
rm -f lambda/lambda_handler lambda_function.zip

echo "🎉 CloudSQLite is ready to use!"
