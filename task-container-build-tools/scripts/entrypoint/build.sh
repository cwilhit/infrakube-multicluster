#!/bin/bash
set -e
cd "$(dirname "$0")"

# Create a local bin directory to store the output
mkdir -p bin

echo "Building for linux/amd64..."
docker buildx build --platform linux/amd64 -f Containerfile.build -o type=local,dest=./bin/amd64 .

echo "Building for linux/arm64..."
docker buildx build --platform linux/arm64 -f Containerfile.build -o type=local,dest=./bin/arm64 .

# Rename and organize binaries
mv bin/amd64/entrypoint bin/entrypoint-amd64
mv bin/arm64/entrypoint bin/entrypoint-arm64
rm -rf bin/amd64 bin/arm64

echo "--------------------------------------------------------"
echo "Build complete."
echo "AMD64 binary: task-container-build-tools/scripts/entrypoint/bin/entrypoint-amd64"
echo "ARM64 binary: task-container-build-tools/scripts/entrypoint/bin/entrypoint-arm64"
echo "--------------------------------------------------------"
