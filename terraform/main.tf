data "aws_caller_identity" "current" {}

# S3 bucket for storing historical data
resource "aws_s3_bucket" "gbfs_historical_data" {
  bucket = "${var.environment}-${var.project_name}-historical-data"
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.gbfs_historical_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Add lifecycle rules
resource "aws_s3_bucket_lifecycle_configuration" "bucket_lifecycle" {
  bucket = aws_s3_bucket.gbfs_historical_data.id

  rule {
    id     = "archive_old_data"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }
  }
}

# Add a bucket policy to explicitly allow QuickSight access
resource "aws_s3_bucket_policy" "quicksight_access" {
  bucket = aws_s3_bucket.gbfs_historical_data.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { 
        Sid    = "AllowQuickSightS3Access"
        Effect = "Allow"
        Principal = {
          Service = "quicksight.amazonaws.com"
        }
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = [
          aws_s3_bucket.gbfs_historical_data.arn,
          "${aws_s3_bucket.gbfs_historical_data.arn}/*"
        ]
      }
    ]
  })
}

# Create a single consolidated manifest file
resource "aws_s3_object" "quicksight_manifest" {
  bucket  = aws_s3_bucket.gbfs_historical_data.id
  key     = "manifest.json"
  content = jsonencode({
    fileLocations = [
      {
        URIPrefixes = [
          "s3://${aws_s3_bucket.gbfs_historical_data.id}/data/",    # Historical data directory
          "s3://${aws_s3_bucket.gbfs_historical_data.id}/realtime/" # Realtime data directory
        ]
      }
    ],
    globalUploadSettings = {
      format         = "JSON"
      delimiter      = ","
      textqualifier = "'"
      containsHeader = "true"
    }
  })
  content_type = "application/json"
  acl          = "private"
}

resource "aws_s3_object" "data_folders" {
  for_each = toset(["data/", "realtime/"])
  
  bucket        = aws_s3_bucket.gbfs_historical_data.id
  key           = each.key
  content_type  = "application/x-directory"
}


# IAM role for QuickSight
resource "aws_iam_role" "quicksight_role" {
  name = "${var.environment}-${var.project_name}-quicksight-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "quicksight.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "quicksight_policy" {
  name = "${var.environment}-${var.project_name}-quicksight-policy"
  role = aws_iam_role.quicksight_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          aws_s3_bucket.gbfs_historical_data.arn,
          "${aws_s3_bucket.gbfs_historical_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "quicksight:PassDataSource",
          "quicksight:DescribeDataSource",
          "quicksight:CreateDataSource",
          "quicksight:UpdateDataSource"
        ]
        Resource = "arn:aws:quicksight:*:${data.aws_caller_identity.current.account_id}:datasource/*"
      }
    ]
  })
}


# QuickSight resources
resource "aws_quicksight_account_subscription" "quicksight" {
  account_name          = "${var.environment}-${var.project_name}"
  authentication_method = "IAM_AND_QUICKSIGHT"
  edition              = "ENTERPRISE"  # or "ENTERPRISE" based on your needs
  notification_email   = var.notification_email
  aws_account_id      = data.aws_caller_identity.current.account_id
  
}


resource "aws_quicksight_data_source" "gbfs_s3" {
  depends_on = [
    aws_quicksight_account_subscription.quicksight,
    aws_iam_role_policy.quicksight_policy,
    aws_s3_bucket_policy.quicksight_access,
    aws_s3_object.quicksight_manifest
  ]

  data_source_id = "${var.environment}-${var.project_name}-s3-source"
  aws_account_id = data.aws_caller_identity.current.account_id
  name           = "GBFS Historical Data"
  type           = "S3"

  parameters {
    s3 {
      manifest_file_location {
        bucket = aws_s3_bucket.gbfs_historical_data.id
        key    = aws_s3_object.quicksight_manifest.key
      }
    }
  }
  
  permission {
    actions   = [
      "quicksight:UpdateDataSourcePermissions", 
      "quicksight:DescribeDataSource", 
      "quicksight:DescribeDataSourcePermissions", 
      "quicksight:PassDataSource", 
      "quicksight:UpdateDataSource", 
      "quicksight:DeleteDataSource"
      ]
    principal = aws_iam_role.quicksight_role.arn
  }

  ssl_properties {
    disable_ssl = false
  }

  tags = {
    Environment = var.environment
  }
}

# Set up incremental refresh 
resource "aws_quicksight_refresh_schedule" "incremental_refresh" {
  depends_on = [aws_quicksight_data_source.gbfs_s3]

  aws_account_id = data.aws_caller_identity.current.account_id
  data_set_id     = aws_quicksight_data_source.gbfs_s3.data_source_id
  schedule_id    = "IncrementalRefresh"

  schedule {
    refresh_type = "INCREMENTAL_REFRESH"
    start_after_date_time = "2024-10-28T00:00:00"
    schedule_frequency {
      interval = "MINUTE15"  
    }
  }
}



# IAM role for Lambda functions
resource "aws_iam_role" "lambda_role" {
  name = "${var.environment}-${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}

# Basic Lambda execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for Lambda to access other AWS services
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.environment}-${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.gbfs_historical_data.arn,
          "${aws_s3_bucket.gbfs_historical_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.alerts.arn
        ]
      }
    ]
  })
}

# Lambda function for data collection
resource "aws_lambda_function" "gbfs_collector" {
  filename      = "../build/collector.zip"
  function_name    = "${var.environment}-${var.project_name}-collector"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 300

  environment {
    variables = {
      PROVIDERS = jsonencode(var.gbfs_providers)
      S3_BUCKET = aws_s3_bucket.gbfs_historical_data.id
    }
  }

  tags = {
    Environment = var.environment
  }
}

# CloudWatch Event Rule to trigger Lambda
resource "aws_cloudwatch_event_rule" "collector_schedule" {
  name                = "${var.environment}-${var.project_name}-collector-schedule"
  description         = "Trigger GBFS data collection every 5 minutes"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "collector_target" {
  rule      = aws_cloudwatch_event_rule.collector_schedule.name
  target_id = "CollectorLambda"
  arn       = aws_lambda_function.gbfs_collector.arn
}

# Add required S3 permissions to Lambda role
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "${var.environment}-${var.project_name}-lambda-s3-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.gbfs_historical_data.arn,
          "${aws_s3_bucket.gbfs_historical_data.arn}/*"
        ]
      }
    ]
  })
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.environment}-${var.project_name}-alerts"
}

# API Gateway for dashboard data
resource "aws_api_gateway_rest_api" "gbfs_api" {
  name = "${var.environment}-${var.project_name}-api"
  
  tags = {
    Environment = var.environment
  }
}

