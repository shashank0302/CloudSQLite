# CloudSQLite - Terraform Variables

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket to store SQLite databases"
  type        = string
  default     = "cloudsqlite-databases"
}

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table for locking"
  type        = string
  default     = "CloudSQLite-Locks"
}

variable "lambda_function_name" {
  description = "Name of the Lambda function"
  type        = string
  default     = "cloudsqlite-lambda"
}

variable "api_gateway_name" {
  description = "Name of the API Gateway"
  type        = string
  default     = "cloudsqlite-api"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name for tagging"
  type        = string
  default     = "CloudSQLite"
}
