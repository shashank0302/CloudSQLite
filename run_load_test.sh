#!/bin/bash

# CloudSQLite Load Test Runner

set -e

# Default configuration
API_URL=""
TOTAL_REQUESTS=100
CONCURRENCY=10
TIMEOUT=30

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --url URL           API Gateway URL (required)"
    echo "  -r, --requests NUM      Total number of requests (default: 100)"
    echo "  -c, --concurrency NUM   Number of concurrent requests (default: 10)"
    echo "  -t, --timeout SEC       Request timeout in seconds (default: 30)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -u https://abc123.execute-api.us-east-1.amazonaws.com/prod/sql -r 200 -c 20"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)
            API_URL="$2"
            shift 2
            ;;
        -r|--requests)
            TOTAL_REQUESTS="$2"
            shift 2
            ;;
        -c|--concurrency)
            CONCURRENCY="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_color $RED "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$API_URL" ]]; then
    print_color $RED "❌ API URL is required. Use -u or --url option."
    show_usage
    exit 1
fi

# Check if Go is installed
if ! command -v go &> /dev/null; then
    print_color $RED "❌ Go is not installed. Please install it first."
    exit 1
fi

# Check if the API URL is reachable
print_color $BLUE "🔍 Checking API connectivity..."
if ! curl -s --connect-timeout 5 "$API_URL" > /dev/null 2>&1; then
    print_color $YELLOW "⚠️  Warning: Could not reach API URL. Continuing anyway..."
fi

# Create a temporary load test file with the configuration
cat > load_test_temp.go << EOF
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"sort"
	"sync"
	"time"
)

// LoadTestConfig represents the configuration for load testing
type LoadTestConfig struct {
	APIURL        string
	TotalRequests int
	Concurrency   int
	Timeout       time.Duration
}

// LoadTestResult represents the result of a single request
type LoadTestResult struct {
	StatusCode int
	Duration   time.Duration
	Error      error
	Success    bool
}

// LoadTestSummary represents the summary of all load test results
type LoadTestSummary struct {
	TotalRequests    int
	SuccessfulRequests int
	FailedRequests   int
	TotalDuration    time.Duration
	AverageLatency   time.Duration
	MinLatency       time.Duration
	MaxLatency       time.Duration
	P50Latency       time.Duration
	P95Latency       time.Duration
	P99Latency       time.Duration
	RequestsPerSecond float64
	ErrorRate        float64
}

// APIRequest represents the request payload
type APIRequest struct {
	SQLStatement string \`json:"sql_statement"\`
	DatabaseName string \`json:"database_name,omitempty"\`
}

// APIResponse represents the API response
type APIResponse struct {
	StatusCode int         \`json:"statusCode"\`
	Body       interface{} \`json:"body"\`
	Headers    map[string]string \`json:"headers"\`
}

func main() {
	// Configuration
	config := LoadTestConfig{
		APIURL:        "$API_URL",
		TotalRequests: $TOTAL_REQUESTS,
		Concurrency:   $CONCURRENCY,
		Timeout:       ${TIMEOUT} * time.Second,
	}

	fmt.Println("🚀 Starting CloudSQLite Load Test")
	fmt.Printf("📊 Configuration:\n")
	fmt.Printf("   API URL: %s\n", config.APIURL)
	fmt.Printf("   Total Requests: %d\n", config.TotalRequests)
	fmt.Printf("   Concurrency: %d\n", config.Concurrency)
	fmt.Printf("   Timeout: %v\n", config.Timeout)
	fmt.Println()

	// Run load test
	summary := runLoadTest(config)

	// Print results
	printResults(summary)
}

// runLoadTest executes the load test with the given configuration
func runLoadTest(config LoadTestConfig) LoadTestSummary {
	startTime := time.Now()
	results := make([]LoadTestResult, 0, config.TotalRequests)
	var mutex sync.Mutex
	var wg sync.WaitGroup

	// Create a semaphore to limit concurrency
	semaphore := make(chan struct{}, config.Concurrency)

	// Create HTTP client with timeout
	client := &http.Client{
		Timeout: config.Timeout,
	}

	// Generate test SQL statements
	testStatements := []string{
		"SELECT 1 as test;",
		"INSERT INTO logs (message, timestamp) VALUES ('Load test message', datetime('now'));",
		"SELECT COUNT(*) as count FROM logs;",
		"SELECT * FROM logs ORDER BY timestamp DESC LIMIT 5;",
		"UPDATE logs SET message = 'Updated message' WHERE id = 1;",
	}

	for i := 0; i < config.TotalRequests; i++ {
		wg.Add(1)
		go func(requestID int) {
			defer wg.Done()

			// Acquire semaphore
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			// Select a random SQL statement
			sqlStatement := testStatements[requestID%len(testStatements)]

			// Create request payload
			payload := APIRequest{
				SQLStatement: sqlStatement,
				DatabaseName: "test.db",
			}

			// Execute request
			result := executeRequest(client, config.APIURL, payload)

			// Store result
			mutex.Lock()
			results = append(results, result)
			mutex.Unlock()

			// Print progress
			if (requestID+1)%10 == 0 {
				fmt.Printf("📈 Completed %d/%d requests\n", requestID+1, config.TotalRequests)
			}
		}(i)
	}

	// Wait for all requests to complete
	wg.Wait()
	totalDuration := time.Since(startTime)

	// Calculate summary
	return calculateSummary(results, totalDuration)
}

// executeRequest executes a single HTTP request
func executeRequest(client *http.Client, apiURL string, payload APIRequest) LoadTestResult {
	startTime := time.Now()

	// Marshal payload
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return LoadTestResult{
			Duration: time.Since(startTime),
			Error:    fmt.Errorf("failed to marshal payload: %v", err),
			Success:  false,
		}
	}

	// Create request
	req, err := http.NewRequest("POST", apiURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return LoadTestResult{
			Duration: time.Since(startTime),
			Error:    fmt.Errorf("failed to create request: %v", err),
			Success:  false,
		}
	}

	req.Header.Set("Content-Type", "application/json")

	// Execute request
	resp, err := client.Do(req)
	if err != nil {
		return LoadTestResult{
			Duration: time.Since(startTime),
			Error:    fmt.Errorf("request failed: %v", err),
			Success:  false,
		}
	}
	defer resp.Body.Close()

	// Read response body
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return LoadTestResult{
			Duration:   time.Since(startTime),
			StatusCode: resp.StatusCode,
			Error:      fmt.Errorf("failed to read response: %v", err),
			Success:    false,
		}
	}

	// Parse response
	var apiResp APIResponse
	if err := json.Unmarshal(body, &apiResp); err != nil {
		return LoadTestResult{
			Duration:   time.Since(startTime),
			StatusCode: resp.StatusCode,
			Error:      fmt.Errorf("failed to parse response: %v", err),
			Success:    false,
		}
	}

	// Check if request was successful
	success := resp.StatusCode >= 200 && resp.StatusCode < 300

	return LoadTestResult{
		Duration:   time.Since(startTime),
		StatusCode: resp.StatusCode,
		Success:    success,
		Error:      nil,
	}
}

// calculateSummary calculates the summary statistics from the results
func calculateSummary(results []LoadTestResult, totalDuration time.Duration) LoadTestSummary {
	if len(results) == 0 {
		return LoadTestSummary{}
	}

	// Sort durations for percentile calculations
	durations := make([]time.Duration, 0, len(results))
	successfulRequests := 0
	failedRequests := 0

	for _, result := range results {
		durations = append(durations, result.Duration)
		if result.Success {
			successfulRequests++
		} else {
			failedRequests++
		}
	}

	sort.Slice(durations, func(i, j int) bool {
		return durations[i] < durations[j]
	})

	// Calculate statistics
	totalLatency := time.Duration(0)
	for _, duration := range durations {
		totalLatency += duration
	}

	avgLatency := totalLatency / time.Duration(len(durations))
	minLatency := durations[0]
	maxLatency := durations[len(durations)-1]

	// Calculate percentiles
	p50Index := int(float64(len(durations)) * 0.5)
	p95Index := int(float64(len(durations)) * 0.95)
	p99Index := int(float64(len(durations)) * 0.99)

	p50Latency := durations[p50Index]
	p95Latency := durations[p95Index]
	p99Latency := durations[p99Index]

	// Calculate requests per second
	requestsPerSecond := float64(len(results)) / totalDuration.Seconds()

	// Calculate error rate
	errorRate := float64(failedRequests) / float64(len(results)) * 100

	return LoadTestSummary{
		TotalRequests:      len(results),
		SuccessfulRequests: successfulRequests,
		FailedRequests:     failedRequests,
		TotalDuration:      totalDuration,
		AverageLatency:     avgLatency,
		MinLatency:         minLatency,
		MaxLatency:         maxLatency,
		P50Latency:         p50Latency,
		P95Latency:         p95Latency,
		P99Latency:         p99Latency,
		RequestsPerSecond:  requestsPerSecond,
		ErrorRate:          errorRate,
	}
}

// printResults prints the load test results in a formatted way
func printResults(summary LoadTestSummary) {
	fmt.Println()
	fmt.Println("📊 Load Test Results")
	fmt.Println("===================")
	fmt.Printf("Total Requests:      %d\n", summary.TotalRequests)
	fmt.Printf("Successful Requests: %d\n", summary.SuccessfulRequests)
	fmt.Printf("Failed Requests:     %d\n", summary.FailedRequests)
	fmt.Printf("Error Rate:          %.2f%%\n", summary.ErrorRate)
	fmt.Println()
	fmt.Printf("Total Duration:      %v\n", summary.TotalDuration)
	fmt.Printf("Requests/Second:     %.2f\n", summary.RequestsPerSecond)
	fmt.Println()
	fmt.Println("Latency Statistics:")
	fmt.Printf("  Average:           %v\n", summary.AverageLatency)
	fmt.Printf("  Min:               %v\n", summary.MinLatency)
	fmt.Printf("  Max:               %v\n", summary.MaxLatency)
	fmt.Printf("  P50 (Median):      %v\n", summary.P50Latency)
	fmt.Printf("  P95:               %v\n", summary.P95Latency)
	fmt.Printf("  P99:               %v\n", summary.P99Latency)
	fmt.Println()

	// Performance assessment
	fmt.Println("🎯 Performance Assessment:")
	if summary.ErrorRate < 1.0 {
		fmt.Println("✅ Excellent: Error rate < 1%")
	} else if summary.ErrorRate < 5.0 {
		fmt.Println("⚠️  Good: Error rate < 5%")
	} else {
		fmt.Println("❌ Poor: Error rate >= 5%")
	}

	if summary.AverageLatency < 1*time.Second {
		fmt.Println("✅ Excellent: Average latency < 1s")
	} else if summary.AverageLatency < 3*time.Second {
		fmt.Println("⚠️  Good: Average latency < 3s")
	} else {
		fmt.Println("❌ Poor: Average latency >= 3s")
	}

	if summary.RequestsPerSecond > 10 {
		fmt.Println("✅ Excellent: > 10 requests/second")
	} else if summary.RequestsPerSecond > 5 {
		fmt.Println("⚠️  Good: > 5 requests/second")
	} else {
		fmt.Println("❌ Poor: <= 5 requests/second")
	}

	fmt.Println()
	fmt.Println("🎉 Load test completed!")
}
EOF

# Run the load test
print_color $GREEN "🚀 Starting CloudSQLite Load Test..."
print_color $BLUE "📊 Configuration:"
print_color $BLUE "   API URL: $API_URL"
print_color $BLUE "   Total Requests: $TOTAL_REQUESTS"
print_color $BLUE "   Concurrency: $CONCURRENCY"
print_color $BLUE "   Timeout: ${TIMEOUT}s"
echo ""

# Compile and run the load test
go run load_test_temp.go

# Clean up
rm -f load_test_temp.go

print_color $GREEN "✨ Load test completed!"
