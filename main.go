package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const (
	// Simulated S3 paths
	s3Path   = "./s3_storage"
	dbFile   = "test.db"
	lockFile = "lock.json"

	// Lock timeout - consider lock stale after 30 seconds
	lockTimeout = 30 * time.Second
)

// LockInfo represents the lock file structure
type LockInfo struct {
	PID       int       `json:"pid"`
	Timestamp time.Time `json:"timestamp"`
	Process   string    `json:"process"`
}

// acquireLock attempts to acquire a lock on the database
func acquireLock() error {
	lockPath := filepath.Join(s3Path, lockFile)

	// Check if lock file exists
	if _, err := os.Stat(lockPath); err == nil {
		// Lock file exists, check if it's stale
		if err := checkLockValidity(lockPath); err != nil {
			return fmt.Errorf("lock is held by another process: %v", err)
		}
	}

	// Create lock file
	lockInfo := LockInfo{
		PID:       os.Getpid(),
		Timestamp: time.Now(),
		Process:   "cloudsqlite",
	}

	lockData, err := json.Marshal(lockInfo)
	if err != nil {
		return fmt.Errorf("failed to marshal lock info: %v", err)
	}

	if err := os.WriteFile(lockPath, lockData, 0644); err != nil {
		return fmt.Errorf("failed to create lock file: %v", err)
	}

	fmt.Printf("Lock acquired by PID %d\n", lockInfo.PID)
	return nil
}

// releaseLock removes the lock file
func releaseLock() error {
	lockPath := filepath.Join(s3Path, lockFile)
	if err := os.Remove(lockPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to release lock: %v", err)
	}
	fmt.Println("Lock released")
	return nil
}

// checkLockValidity checks if the existing lock is valid (not stale)
func checkLockValidity(lockPath string) error {
	data, err := os.ReadFile(lockPath)
	if err != nil {
		return fmt.Errorf("failed to read lock file: %v", err)
	}

	var lockInfo LockInfo
	if err := json.Unmarshal(data, &lockInfo); err != nil {
		return fmt.Errorf("failed to unmarshal lock info: %v", err)
	}

	// Check if lock is stale
	if time.Since(lockInfo.Timestamp) > lockTimeout {
		fmt.Printf("Lock is stale (age: %v), removing it\n", time.Since(lockInfo.Timestamp))
		return os.Remove(lockPath)
	}

	// Check if the process is still running
	if !isProcessRunning(lockInfo.PID) {
		fmt.Printf("Process %d is no longer running, removing stale lock\n", lockInfo.PID)
		return os.Remove(lockPath)
	}

	return fmt.Errorf("lock is held by active process %d since %v", lockInfo.PID, lockInfo.Timestamp)
}

// isProcessRunning checks if a process with the given PID is running
func isProcessRunning(pid int) bool {
	// Try to send signal 0 to check if process exists
	err := syscall.Kill(pid, 0)
	return err == nil
}

func main() {
	// Create S3 simulation directory
	if err := os.MkdirAll(s3Path, 0755); err != nil {
		log.Fatalf("Failed to create S3 directory: %v", err)
	}

	// Initialize database if it doesn't exist
	if err := initializeDatabase(); err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}

	// Acquire lock before transaction
	if err := acquireLock(); err != nil {
		log.Fatalf("Failed to acquire lock: %v", err)
	}
	defer releaseLock() // Ensure lock is released

	// Simulate database transaction
	if err := performTransaction(); err != nil {
		log.Fatalf("Transaction failed: %v", err)
	}

	fmt.Println("Transaction completed successfully!")
}

// initializeDatabase creates the initial database with a logs table
func initializeDatabase() error {
	dbPath := filepath.Join(s3Path, dbFile)

	// Check if database already exists
	if _, err := os.Stat(dbPath); err == nil {
		fmt.Println("Database already exists, skipping initialization")
		return nil
	}

	// Create new database
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return fmt.Errorf("failed to open database: %v", err)
	}
	defer db.Close()

	// Create logs table
	createTableSQL := `
	CREATE TABLE IF NOT EXISTS logs (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		message TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);`

	if _, err := db.Exec(createTableSQL); err != nil {
		return fmt.Errorf("failed to create table: %v", err)
	}

	fmt.Println("Database initialized successfully")
	return nil
}

// performTransaction downloads, modifies, and uploads the database
func performTransaction() error {
	// Step 1: Download database from S3 (simulate)
	fmt.Println("Downloading database from S3...")
	localDBPath := "./temp_" + dbFile
	if err := copyFile(filepath.Join(s3Path, dbFile), localDBPath); err != nil {
		return fmt.Errorf("failed to download database: %v", err)
	}
	defer os.Remove(localDBPath) // Clean up temp file

	// Step 2: Perform SQL operation
	fmt.Println("Performing SQL operation...")
	if err := modifyDatabase(localDBPath); err != nil {
		return fmt.Errorf("failed to modify database: %v", err)
	}

	// Step 3: Upload modified database back to S3 (simulate)
	fmt.Println("Uploading modified database to S3...")
	if err := copyFile(localDBPath, filepath.Join(s3Path, dbFile)); err != nil {
		return fmt.Errorf("failed to upload database: %v", err)
	}

	return nil
}

// modifyDatabase performs the actual SQL operation
func modifyDatabase(dbPath string) error {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return fmt.Errorf("failed to open database: %v", err)
	}
	defer db.Close()

	// Insert a test log entry
	insertSQL := `INSERT INTO logs (message) VALUES (?)`
	message := fmt.Sprintf("Test log entry at %s", time.Now().Format(time.RFC3339))

	if _, err := db.Exec(insertSQL, message); err != nil {
		return fmt.Errorf("failed to insert log: %v", err)
	}

	// Verify the insertion
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM logs").Scan(&count); err != nil {
		return fmt.Errorf("failed to count logs: %v", err)
	}

	fmt.Printf("Successfully inserted log entry. Total logs: %d\n", count)
	return nil
}

// copyFile copies a file from src to dst
func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, sourceFile)
	return err
}
