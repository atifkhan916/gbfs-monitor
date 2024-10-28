#!/bin/bash

# Function to check if bucket exists and create if it doesn't
setup_terraform_backend() {
    local bucket_name="$1"
    local region="$2"

    echo "Checking if bucket $bucket_name exists..."
    
    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        echo "Bucket $bucket_name already exists"
    else
        echo "Bucket $bucket_name does not exist. Creating..."
        
        # Create the bucket
        if aws s3api create-bucket \
            --bucket "$bucket_name" \
            --region "$region" \
            --create-bucket-configuration LocationConstraint="$region"; then
            
            echo "Bucket created successfully"
            
            # Enable versioning
            aws s3api put-bucket-versioning \
                --bucket "$bucket_name" \
                --versioning-configuration Status=Enabled
            
            echo "Bucket versioning enabled"
            
            # Add bucket encryption
            aws s3api put-bucket-encryption \
                --bucket "$bucket_name" \
                --server-side-encryption-configuration '{
                    "Rules": [
                        {
                            "ApplyServerSideEncryptionByDefault": {
                                "SSEAlgorithm": "AES256"
                            }
                        }
                    ]
                }'
            
            echo "Bucket encryption enabled"
            
            # Block public access
            aws s3api put-public-access-block \
                --bucket "$bucket_name" \
                --public-access-block-configuration '{
                    "BlockPublicAcls": true,
                    "IgnorePublicAcls": true,
                    "BlockPublicPolicy": true,
                    "RestrictPublicBuckets": true
                }'
            
            echo "Public access blocked"
        else
            echo "Failed to create bucket"
            exit 1
        fi
    fi
}
