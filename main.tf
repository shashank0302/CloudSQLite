# CloudSQLite - Terraform Infrastructure Configuration
# This configuration creates the complete AWS infrastructure for CloudSQLite

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = var.aws_region
}

# Variables are defined in variables.tf

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# S3 Bucket for SQLite databases
resource "aws_s3_bucket" "sqlite_databases" {
  bucket = var.s3_bucket_name

  tags = {
    Name        = "CloudSQLite Database Storage"
    Environment = "production"
    Project     = "CloudSQLite"
  }
}

# S3 Bucket versioning
resource "aws_s3_bucket_versioning" "sqlite_databases" {
  bucket = aws_s3_bucket.sqlite_databases.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket public access block
resource "aws_s3_bucket_public_access_block" "sqlite_databases" {
  bucket = aws_s3_bucket.sqlite_databases.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB table for distributed locking
resource "aws_dynamodb_table" "locks" {
  name           = var.dynamodb_table_name
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "database_name"

  attribute {
    name = "database_name"
    type = "S"
  }

  ttl {
    attribute_name = "lease_timeout"
    enabled        = true
  }

  tags = {
    Name        = "CloudSQLite Locks"
    Environment = "production"
    Project     = "CloudSQLite"
  }
}

# IAM Role for Lambda function
resource "aws_iam_role" "lambda_execution_role" {
  name = "CloudSQLite-Lambda-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "CloudSQLite Lambda Execution Role"
    Environment = "production"
    Project     = "CloudSQLite"
  }
}

# Attach basic execution role policy
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for S3 and DynamoDB access
resource "aws_iam_role_policy" "lambda_cloudsqlite_policy" {
  name = "CloudSQLitePolicy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.sqlite_databases.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.locks.arn
      }
    ]
  })
}

# Build the Go Lambda function
resource "null_resource" "build_lambda" {
  triggers = {
    source_code_hash = filemd5("${path.module}/lambda/main.go")
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}/lambda
      GOOS=linux GOARCH=amd64 go build -o lambda_handler main.go
    EOT
  }
}

# Create deployment package
data "archive_file" "lambda_zip" {
  depends_on = [null_resource.build_lambda]
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_handler"
  output_path = "${path.module}/lambda_function.zip"
}

# Lambda function
resource "aws_lambda_function" "cloudsqlite_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = var.lambda_function_name
  role            = aws_iam_role.lambda_execution_role.arn
  handler         = "lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime         = "go1.x"
  timeout         = 300
  memory_size     = 512

  environment {
    variables = {
      S3_BUCKET_NAME      = aws_s3_bucket.sqlite_databases.bucket
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.locks.name
    }
  }

  tags = {
    Name        = "CloudSQLite Lambda Function"
    Environment = "production"
    Project     = "CloudSQLite"
  }
}

# API Gateway
resource "aws_api_gateway_rest_api" "cloudsqlite_api" {
  name        = var.api_gateway_name
  description = "CloudSQLite API Gateway"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name        = "CloudSQLite API Gateway"
    Environment = "production"
    Project     = "CloudSQLite"
  }
}

# API Gateway Resource
resource "aws_api_gateway_resource" "sql_resource" {
  rest_api_id = aws_api_gateway_rest_api.cloudsqlite_api.id
  parent_id   = aws_api_gateway_rest_api.cloudsqlite_api.root_resource_id
  path_part   = "sql"
}

# API Gateway Method
resource "aws_api_gateway_method" "sql_method" {
  rest_api_id   = aws_api_gateway_rest_api.cloudsqlite_api.id
  resource_id   = aws_api_gateway_resource.sql_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

# API Gateway Integration
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id = aws_api_gateway_rest_api.cloudsqlite_api.id
  resource_id = aws_api_gateway_resource.sql_resource.id
  http_method = aws_api_gateway_method.sql_method.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.cloudsqlite_lambda.invoke_arn
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cloudsqlite_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cloudsqlite_api.execution_arn}/*/*"
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "cloudsqlite_deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda_integration,
    aws_lambda_permission.api_gateway_lambda
  ]

  rest_api_id = aws_api_gateway_rest_api.cloudsqlite_api.id
  stage_name  = "prod"

  lifecycle {
    create_before_destroy = true
  }
}

# Outputs
output "api_gateway_url" {
  description = "API Gateway URL for CloudSQLite"
  value       = "${aws_api_gateway_deployment.cloudsqlite_deployment.invoke_url}/sql"
}

output "s3_bucket_name" {
  description = "S3 bucket name for SQLite databases"
  value       = aws_s3_bucket.sqlite_databases.bucket
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for locking"
  value       = aws_dynamodb_table.locks.name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.cloudsqlite_lambda.arn
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.cloudsqlite_lambda.function_name
}
