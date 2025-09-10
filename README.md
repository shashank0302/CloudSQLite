# CloudSQLite - Serverless SQLite Database with AWS Lambda

A serverless SQLite database solution that enables SQL operations on cloud-stored databases using AWS Lambda, S3, and DynamoDB for distributed locking.

## 🎯 Problem This Solves

Traditional SQLite databases are file-based and don't work well in serverless environments where:
- Multiple Lambda functions need to access the same database
- File systems are ephemeral and not shared between invocations
- Concurrent access can lead to data corruption
- Scaling requires complex database management

CloudSQLite solves this by:
- Storing SQLite databases in S3 for persistence
- Using DynamoDB for distributed locking to prevent concurrent access
- Providing a REST API through API Gateway
- Enabling serverless SQL operations with proper concurrency control

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Client App    │───▶│   API Gateway   │───▶│  Lambda Function│
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                                        │
                       ┌─────────────────────────────────┼─────────────────────────────────┐
                       │                                 │                                 │
                       ▼                                 ▼                                 ▼
              ┌─────────────────┐              ┌─────────────────┐              ┌─────────────────┐
              │   S3 Bucket     │              │  DynamoDB Table │              │  CloudWatch     │
              │ SQLite Databases│              │  Distributed    │              │     Logs        │
              │                 │              │     Locks       │              │                 │
              └─────────────────┘              └─────────────────┘              └─────────────────┘

Lambda Execution Flow:
1. Acquire Lock (DynamoDB) ──▶ 2. Download DB (S3) ──▶ 3. Execute SQL ──▶ 4. Upload DB (S3) ──▶ 5. Release Lock (DynamoDB)

Infrastructure Management:
┌─────────────────┐
│   Terraform     │───▶ Deploys all AWS resources
└─────────────────┘
```

## 🔧 Key Components

### 1. **S3 Storage**
- Stores SQLite database files
- Versioning enabled for data protection
- Private access with proper IAM permissions

### 2. **DynamoDB Locking**
- Prevents concurrent database access
- TTL-based automatic lock expiration
- Race condition prevention with conditional writes

### 3. **Lambda Function**
- Executes SQL operations on downloaded databases
- Handles API Gateway requests
- Manages lock acquisition and release
- Supports both SELECT and non-SELECT queries

### 4. **API Gateway**
- RESTful API interface
- Handles HTTP requests and responses
- Integrates with Lambda function

## ⚖️ Trade-offs

### ✅ Advantages
- **Serverless**: No server management required
- **Cost-effective**: Pay only for actual usage
- **Scalable**: Handles concurrent requests with proper locking
- **Simple**: Easy to deploy and use
- **Familiar**: Uses standard SQLite syntax

### ❌ Limitations
- **Not suitable for high-write throughput**: Each write requires download/upload cycle
- **Latency**: S3 operations add overhead (typically 200-500ms per operation)
- **Concurrency**: Only one writer at a time due to locking mechanism
- **Database size**: Large databases increase download/upload time
- **No ACID transactions**: Each operation is atomic but not transactional across operations

### 🎯 Best Use Cases
- Read-heavy workloads with occasional writes
- Microservices that need simple data persistence
- Prototyping and development environments
- Applications with infrequent database updates
- Logging and audit trail systems

## 🚀 Quick Start

### Prerequisites
- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- Go >= 1.19
- Git

### 1. Clone the Repository
```bash
git clone <repository-url>
cd CloudSQLite/cloudsqlite
```

### 2. Deploy Infrastructure
```bash
# Using Terraform (Recommended)
./deploy_terraform.sh

# Or using CloudFormation
aws cloudformation create-stack \
  --stack-name cloudsqlite \
  --template-body file://cloudformation.yaml \
  --capabilities CAPABILITY_NAMED_IAM
```

### 3. Test the API
```bash
# Get the API URL from Terraform output
API_URL=$(terraform output -raw api_gateway_url)

# Test with a simple query
curl -X POST $API_URL \
  -H "Content-Type: application/json" \
  -d '{"sql_statement": "SELECT 1 as test;"}'
```

### 4. Run Load Tests
```bash
# Basic load test
./run_load_test.sh -u $API_URL -r 100 -c 10

# Advanced load test
./run_load_test.sh -u $API_URL -r 500 -c 25 -t 60
```

## 📋 Step-by-Step Deployment Guide

### Phase 1: Local Development
1. **Set up local environment**
   ```bash
   go mod init cloudsqlite
   go get github.com/mattn/go-sqlite3
   ```

2. **Test locally**
   ```bash
   go run main.go
   ```

### Phase 2: AWS Lambda Implementation
1. **Create Lambda function**
   ```bash
   cd lambda
   go mod init cloudsqlite-lambda
   go get github.com/aws/aws-lambda-go/lambda
   go get github.com/aws/aws-sdk-go
   ```

2. **Deploy Lambda**
   ```bash
   ./deploy.sh
   ```

### Phase 3: Infrastructure as Code
1. **Initialize Terraform**
   ```bash
   terraform init
   ```

2. **Plan deployment**
   ```bash
   terraform plan
   ```

3. **Apply configuration**
   ```bash
   terraform apply
   ```

### Phase 4: Testing and Monitoring
1. **Run load tests**
   ```bash
   ./run_load_test.sh -u <API_URL> -r 100 -c 10
   ```

2. **Monitor CloudWatch logs**
   ```bash
   aws logs tail /aws/lambda/cloudsqlite-lambda --follow
   ```

## 🔧 Configuration

### Environment Variables
- `S3_BUCKET_NAME`: S3 bucket for database storage
- `DYNAMODB_TABLE_NAME`: DynamoDB table for locking

### Terraform Variables
- `aws_region`: AWS region (default: us-east-1)
- `s3_bucket_name`: S3 bucket name
- `dynamodb_table_name`: DynamoDB table name
- `lambda_function_name`: Lambda function name
- `api_gateway_name`: API Gateway name

## 📊 Performance Characteristics

### Typical Latency
- **Cold start**: 2-5 seconds
- **Warm execution**: 200-800ms per operation
- **S3 download**: 50-200ms (depends on DB size)
- **S3 upload**: 50-200ms (depends on DB size)
- **DynamoDB operations**: 10-50ms

### Throughput
- **Concurrent requests**: Limited by Lambda concurrency limits
- **Requests per second**: 5-20 (depending on DB size and operation complexity)
- **Database size limit**: Recommended < 50MB for optimal performance

## 🛠️ Development

### Project Structure
```
cloudsqlite/
├── main.go                 # Local proof of concept
├── lambda/
│   ├── main.go            # Lambda function
│   └── go.mod             # Lambda dependencies
├── main.tf                # Terraform configuration
├── variables.tf           # Terraform variables
├── cloudformation.yaml    # CloudFormation template
├── deploy.sh              # CloudFormation deployment
├── deploy_terraform.sh    # Terraform deployment
├── load_test.go           # Load testing script
├── run_load_test.sh       # Load test runner
└── README.md              # This file
```

### Adding New Features
1. **Modify Lambda function** in `lambda/main.go`
2. **Update Terraform** if infrastructure changes needed
3. **Test locally** with `go run main.go`
4. **Deploy** with `./deploy_terraform.sh`
5. **Run load tests** to verify performance

## 🔍 Monitoring and Debugging

### CloudWatch Logs
```bash
# View Lambda logs
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/cloudsqlite

# Tail logs in real-time
aws logs tail /aws/lambda/cloudsqlite-lambda --follow
```

### Common Issues
1. **Lock timeout**: Increase Lambda timeout or reduce operation complexity
2. **S3 access denied**: Check IAM permissions
3. **DynamoDB errors**: Verify table exists and has correct permissions
4. **High latency**: Consider database size and S3 region

## 🧪 Testing

### Unit Tests
```bash
go test ./...
```

### Integration Tests
```bash
# Test API endpoints
curl -X POST $API_URL \
  -H "Content-Type: application/json" \
  -d '{"sql_statement": "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);"}'

curl -X POST $API_URL \
  -H "Content-Type: application/json" \
  -d '{"sql_statement": "INSERT INTO test (name) VALUES (\"Hello World\");"}'

curl -X POST $API_URL \
  -H "Content-Type: application/json" \
  -d '{"sql_statement": "SELECT * FROM test;"}'
```

### Load Testing
```bash
# Light load
./run_load_test.sh -u $API_URL -r 50 -c 5

# Medium load
./run_load_test.sh -u $API_URL -r 200 -c 20

# Heavy load
./run_load_test.sh -u $API_URL -r 500 -c 50
```

## 🚨 Security Considerations

- **IAM Roles**: Least privilege access to S3 and DynamoDB
- **S3 Bucket**: Private access with public access blocked
- **API Gateway**: No authentication (add as needed)
- **DynamoDB**: Encryption at rest enabled
- **Lambda**: VPC configuration available if needed

## 📈 Cost Optimization

### S3 Costs
- Storage: ~$0.023 per GB per month
- Requests: ~$0.0004 per 1,000 requests

### DynamoDB Costs
- On-demand: ~$1.25 per million read/write requests

### Lambda Costs
- Compute: $0.0000166667 per GB-second
- Requests: $0.0000002 per request

### Estimated Monthly Cost
- **Light usage** (1,000 requests): ~$1-2
- **Medium usage** (10,000 requests): ~$5-10
- **Heavy usage** (100,000 requests): ~$20-50

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- AWS Lambda team for serverless computing
- SQLite team for the amazing database engine
- Terraform team for infrastructure as code
- Go team for the excellent programming language

---

**⚠️ Important**: This solution is designed for specific use cases. Evaluate your requirements carefully before using in production. Consider alternatives like RDS, Aurora Serverless, or DynamoDB for high-throughput applications.