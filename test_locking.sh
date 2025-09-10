#!/bin/bash

echo "=== Testing CloudSQLite Locking Mechanism ==="
echo

# Clean up any existing lock file
rm -f s3_storage/lock.json

echo "1. Running first process (should acquire lock)..."
go run main.go &
FIRST_PID=$!

# Wait a moment for the first process to acquire the lock
sleep 1

echo "2. Running second process (should wait for lock)..."
go run main.go &
SECOND_PID=$!

echo "3. Running third process (should wait for lock)..."
go run main.go &
THIRD_PID=$!

# Wait for all processes to complete
wait $FIRST_PID
wait $SECOND_PID
wait $THIRD_PID

echo
echo "=== Final Results ==="
echo "Database contents:"
sqlite3 s3_storage/test.db "SELECT id, message, created_at FROM logs ORDER BY id;"

echo
echo "Total log entries:"
sqlite3 s3_storage/test.db "SELECT COUNT(*) FROM logs;"

echo
echo "Lock file status:"
if [ -f s3_storage/lock.json ]; then
    echo "Lock file still exists (this shouldn't happen):"
    cat s3_storage/lock.json
else
    echo "Lock file properly cleaned up ✓"
fi
