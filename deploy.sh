#!/bin/bash

# Set variables
LAMBDA_DIR="./src/lambdas"
OUTPUT_DIR="./build"
TF_DIR="./terraform"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
if ! command_exists terraform; then
    echo "Terraform is not installed. Please install it and try again."
    exit 1
fi

if ! command_exists npm; then
    echo "npm is not installed. Please install Node.js and npm, then try again."
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Install dependencies
echo "Installing dependencies..."
npm install

# Compile TypeScript files
echo "Compiling TypeScript files..."
npm run build

echo "Zipping Lambda functions..."
for lambda_folder in "$OUTPUT_DIR"/*; do
    if [ -d "$lambda_folder" ]; then
        lambda_name=$(basename "$lambda_folder")
        (cd "$lambda_folder" && zip -r "../${lambda_name}.zip" .)
        echo "Created ${lambda_name}.zip"
    fi
done

# Run Terraform commands
echo "Running Terraform commands..."
cd "$TF_DIR" || exit

echo "Initializing Terraform..."
terraform init

echo "Validating Terraform configuration..."
terraform validate

echo "Generating Terraform plan..."
terraform plan -out=tfplan

echo "Creating resources..."
terraform apply "tfplan"

echo "Script completed!"