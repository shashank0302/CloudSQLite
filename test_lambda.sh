#!/bin/bash

# CloudSQLite Lambda Function Test Script

set -e

# Configuration
API_URL="${API_URL:-https://your-api-id.execute-api.us-east-1.amazonaws.com/prod/sql}"
DATABASE_NAME="${DATABASE_NAME:-database.db}"

echo "🧪 Testing CloudSQLite Lambda Function..."
echo "API URL: $API_URL"
echo ""

# Test 1: Create a test table
echo "📝 Test 1: Creating test table..."
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"CREATE TABLE IF NOT EXISTS test_table (id INTEGER PRIMARY KEY, name TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.'

echo -e "\n"

# Test 2: Insert test data
echo "📝 Test 2: Inserting test data..."
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"INSERT INTO test_table (name) VALUES ('Alice'), ('Bob'), ('Charlie')\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.'

echo -e "\n"

# Test 3: Query the data
echo "📝 Test 3: Querying test data..."
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"SELECT * FROM test_table ORDER BY id\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.'

echo -e "\n"

# Test 4: Update data
echo "📝 Test 4: Updating test data..."
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"UPDATE test_table SET name = 'Alice Updated' WHERE id = 1\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.'

echo -e "\n"

# Test 5: Query updated data
echo "📝 Test 5: Querying updated data..."
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"SELECT * FROM test_table WHERE id = 1\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.'

echo -e "\n"

# Test 6: Test concurrent access (simulate lock contention)
echo "📝 Test 6: Testing concurrent access..."
echo "Starting two concurrent requests..."

# Start first request in background
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"SELECT COUNT(*) as total FROM test_table\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.' &

# Start second request immediately
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"SELECT COUNT(*) as total FROM test_table\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.' &

# Wait for both to complete
wait

echo -e "\n"

# Test 7: Test error handling
echo "📝 Test 7: Testing error handling (invalid SQL)..."
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"sql_statement\": \"INVALID SQL STATEMENT\",
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.'

echo -e "\n"

# Test 8: Test missing SQL statement
echo "📝 Test 8: Testing error handling (missing SQL)..."
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"database_name\": \"$DATABASE_NAME\"
  }" | jq '.'

echo -e "\n"

echo "✅ All tests completed!"
echo ""
echo "💡 To run with a different API URL:"
echo "API_URL=https://your-api-id.execute-api.region.amazonaws.com/prod/sql ./test_lambda.sh"
