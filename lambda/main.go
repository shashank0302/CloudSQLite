package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/dynamodb"
	"github.com/aws/aws-sdk-go/service/dynamodb/dynamodbattribute"
	"github.com/aws/aws-sdk-go/service/s3"
	_ "github.com/mattn/go-sqlite3"
)

const (
	// DynamoDB table for locking
	lockTableName = "CloudSQLite-Locks"

	// S3 configuration
	s3BucketName = "cloudsqlite-databases"
	dbFileName   = "database.db"

	// Lock timeout - 5 minutes
	lockTimeoutMinutes = 5
)

// LockItem represents a DynamoDB lock item
type LockItem struct {
	DatabaseName string `json:"database_name" dynamodbav:"database_name"`
	InstanceID   string `json:"instance_id" dynamodbav:"instance_id"`
	LeaseTimeout int64  `json:"lease_timeout" dynamodbav:"lease_timeout"`
	CreatedAt    int64  `json:"created_at" dynamodbav:"created_at"`
}

// APIRequest represents the incoming API Gateway request
type APIRequest struct {
	SQLStatement string `json:"sql_statement"`
	DatabaseName string `json:"database_name,omitempty"`
}

// APIResponse represents the API Gateway response
type APIResponse struct {
	StatusCode int               `json:"statusCode"`
	Body       interface{}       `json:"body"`
	Headers    map[string]string `json:"headers"`
}

// SQLResult represents the result of a SQL query
type SQLResult struct {
	Success bool        `json:"success"`
	Data    interface{} `json:"data,omitempty"`
	Message string      `json:"message,omitempty"`
	Error   string      `json:"error,omitempty"`
}

var (
	dynamoClient *dynamodb.DynamoDB
	s3Client     *s3.S3
)

func init() {
	// Initialize AWS session
	sess := session.Must(session.NewSession())
	dynamoClient = dynamodb.New(sess)
	s3Client = s3.New(sess)
}

// Handler is the main Lambda function handler
func Handler(ctx context.Context, request events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	// Parse the request body
	var apiReq APIRequest
	if err := json.Unmarshal([]byte(request.Body), &apiReq); err != nil {
		return createErrorResponse(400, "Invalid JSON in request body"), nil
	}

	// Use default database name if not provided
	if apiReq.DatabaseName == "" {
		apiReq.DatabaseName = dbFileName
	}

	// Validate SQL statement
	if apiReq.SQLStatement == "" {
		return createErrorResponse(400, "SQL statement is required"), nil
	}

	// Generate unique instance ID for this Lambda invocation
	instanceID := fmt.Sprintf("lambda-%d", time.Now().UnixNano())

	// Step 1: Acquire lock in DynamoDB
	if err := acquireDynamoLock(apiReq.DatabaseName, instanceID); err != nil {
		return createErrorResponse(409, fmt.Sprintf("Failed to acquire lock: %v", err)), nil
	}

	// Ensure lock is released
	defer releaseDynamoLock(apiReq.DatabaseName, instanceID)

	// Step 2: Download database from S3
	localDBPath, err := downloadFromS3(apiReq.DatabaseName)
	if err != nil {
		return createErrorResponse(500, fmt.Sprintf("Failed to download database: %v", err)), nil
	}
	defer os.Remove(localDBPath) // Clean up local file

	// Step 3: Execute SQL statement
	result, err := executeSQL(localDBPath, apiReq.SQLStatement)
	if err != nil {
		return createErrorResponse(500, fmt.Sprintf("SQL execution failed: %v", err)), nil
	}

	// Step 4: Upload modified database back to S3
	if err := uploadToS3(localDBPath, apiReq.DatabaseName); err != nil {
		return createErrorResponse(500, fmt.Sprintf("Failed to upload database: %v", err)), nil
	}

	// Step 5: Return results
	return createSuccessResponse(result), nil
}

// acquireDynamoLock attempts to acquire a lock in DynamoDB
func acquireDynamoLock(databaseName, instanceID string) error {
	// Check if lock already exists
	getItemInput := &dynamodb.GetItemInput{
		TableName: aws.String(lockTableName),
		Key: map[string]*dynamodb.AttributeValue{
			"database_name": {
				S: aws.String(databaseName),
			},
		},
	}

	result, err := dynamoClient.GetItem(getItemInput)
	if err != nil {
		return fmt.Errorf("failed to check existing lock: %v", err)
	}

	// If item exists, check if it's still valid
	if result.Item != nil {
		var existingLock LockItem
		if err := dynamodbattribute.UnmarshalMap(result.Item, &existingLock); err != nil {
			return fmt.Errorf("failed to unmarshal existing lock: %v", err)
		}

		// Check if lock is still valid (not expired)
		currentTime := time.Now().Unix()
		if existingLock.LeaseTimeout > currentTime {
			return fmt.Errorf("database is locked by instance %s until %d",
				existingLock.InstanceID, existingLock.LeaseTimeout)
		}

		// Lock is expired, remove it
		if err := releaseDynamoLock(databaseName, existingLock.InstanceID); err != nil {
			log.Printf("Warning: Failed to remove expired lock: %v", err)
		}
	}

	// Create new lock item
	now := time.Now()
	leaseTimeout := now.Add(time.Duration(lockTimeoutMinutes) * time.Minute).Unix()

	lockItem := LockItem{
		DatabaseName: databaseName,
		InstanceID:   instanceID,
		LeaseTimeout: leaseTimeout,
		CreatedAt:    now.Unix(),
	}

	// Put item with condition to prevent race conditions
	item, err := dynamodbattribute.MarshalMap(lockItem)
	if err != nil {
		return fmt.Errorf("failed to marshal lock item: %v", err)
	}

	putItemInput := &dynamodb.PutItemInput{
		TableName:           aws.String(lockTableName),
		Item:                item,
		ConditionExpression: aws.String("attribute_not_exists(database_name)"),
	}

	_, err = dynamoClient.PutItem(putItemInput)
	if err != nil {
		return fmt.Errorf("failed to acquire lock (race condition): %v", err)
	}

	log.Printf("Lock acquired for database %s by instance %s", databaseName, instanceID)
	return nil
}

// releaseDynamoLock removes the lock from DynamoDB
func releaseDynamoLock(databaseName, instanceID string) error {
	deleteItemInput := &dynamodb.DeleteItemInput{
		TableName: aws.String(lockTableName),
		Key: map[string]*dynamodb.AttributeValue{
			"database_name": {
				S: aws.String(databaseName),
			},
		},
		ConditionExpression: aws.String("instance_id = :instance_id"),
		ExpressionAttributeValues: map[string]*dynamodb.AttributeValue{
			":instance_id": {
				S: aws.String(instanceID),
			},
		},
	}

	_, err := dynamoClient.DeleteItem(deleteItemInput)
	if err != nil {
		log.Printf("Warning: Failed to release lock: %v", err)
		return err
	}

	log.Printf("Lock released for database %s by instance %s", databaseName, instanceID)
	return nil
}

// downloadFromS3 downloads the database file from S3
func downloadFromS3(databaseName string) (string, error) {
	localPath := fmt.Sprintf("/tmp/%s", databaseName)

	downloadInput := &s3.GetObjectInput{
		Bucket: aws.String(s3BucketName),
		Key:    aws.String(databaseName),
	}

	result, err := s3Client.GetObject(downloadInput)
	if err != nil {
		return "", fmt.Errorf("failed to get object from S3: %v", err)
	}
	defer result.Body.Close()

	// Create local file
	file, err := os.Create(localPath)
	if err != nil {
		return "", fmt.Errorf("failed to create local file: %v", err)
	}
	defer file.Close()

	// Copy S3 object to local file
	if _, err := file.ReadFrom(result.Body); err != nil {
		return "", fmt.Errorf("failed to copy S3 object to local file: %v", err)
	}

	log.Printf("Downloaded database %s from S3 to %s", databaseName, localPath)
	return localPath, nil
}

// uploadToS3 uploads the modified database file back to S3
func uploadToS3(localPath, databaseName string) error {
	file, err := os.Open(localPath)
	if err != nil {
		return fmt.Errorf("failed to open local file: %v", err)
	}
	defer file.Close()

	uploadInput := &s3.PutObjectInput{
		Bucket: aws.String(s3BucketName),
		Key:    aws.String(databaseName),
		Body:   file,
	}

	_, err = s3Client.PutObject(uploadInput)
	if err != nil {
		return fmt.Errorf("failed to upload object to S3: %v", err)
	}

	log.Printf("Uploaded database %s to S3", databaseName)
	return nil
}

// executeSQL executes the SQL statement on the local database
func executeSQL(dbPath, sqlStatement string) (*SQLResult, error) {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %v", err)
	}
	defer db.Close()

	// Determine if this is a SELECT query
	isSelect := len(sqlStatement) > 6 && sqlStatement[:6] == "SELECT"

	if isSelect {
		// Execute SELECT query
		rows, err := db.Query(sqlStatement)
		if err != nil {
			return nil, fmt.Errorf("SELECT query failed: %v", err)
		}
		defer rows.Close()

		// Get column names
		columns, err := rows.Columns()
		if err != nil {
			return nil, fmt.Errorf("failed to get columns: %v", err)
		}

		// Scan results
		var results []map[string]interface{}
		for rows.Next() {
			values := make([]interface{}, len(columns))
			valuePtrs := make([]interface{}, len(columns))
			for i := range values {
				valuePtrs[i] = &values[i]
			}

			if err := rows.Scan(valuePtrs...); err != nil {
				return nil, fmt.Errorf("failed to scan row: %v", err)
			}

			row := make(map[string]interface{})
			for i, col := range columns {
				row[col] = values[i]
			}
			results = append(results, row)
		}

		return &SQLResult{
			Success: true,
			Data:    results,
			Message: fmt.Sprintf("Query executed successfully, returned %d rows", len(results)),
		}, nil
	} else {
		// Execute non-SELECT query (INSERT, UPDATE, DELETE, etc.)
		result, err := db.Exec(sqlStatement)
		if err != nil {
			return nil, fmt.Errorf("query execution failed: %v", err)
		}

		rowsAffected, _ := result.RowsAffected()
		return &SQLResult{
			Success: true,
			Message: fmt.Sprintf("Query executed successfully, %d rows affected", rowsAffected),
		}, nil
	}
}

// createSuccessResponse creates a successful API Gateway response
func createSuccessResponse(data interface{}) events.APIGatewayProxyResponse {
	body, _ := json.Marshal(data)
	return events.APIGatewayProxyResponse{
		StatusCode: 200,
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
		Body: string(body),
	}
}

// createErrorResponse creates an error API Gateway response
func createErrorResponse(statusCode int, message string) events.APIGatewayProxyResponse {
	errorBody := SQLResult{
		Success: false,
		Error:   message,
	}
	body, _ := json.Marshal(errorBody)
	return events.APIGatewayProxyResponse{
		StatusCode: statusCode,
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
		Body: string(body),
	}
}

func main() {
	lambda.Start(Handler)
}
