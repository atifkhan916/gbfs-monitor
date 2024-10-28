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

# Create manifest file
resource "aws_s3_bucket_object" "quicksight_manifest" {
  bucket  = aws_s3_bucket.gbfs_historical_data.id
  key     = "manifest.json"
  content = jsonencode({
    fileLocations = [
      {
        URIPrefixes = [
          "s3://${aws_s3_bucket.gbfs_historical_data.id}/"
        ]
      }
    ],
    globalUploadSettings = {
      format = "JSON",
      delimiter = ",",
      textqualifier = "'",
      containsHeader = "true"
    }
  })
  content_type = "application/json"
}

# QuickSight resources
resource "aws_quicksight_account_subscription" "quicksight" {
  account_name          = "${var.environment}-${var.project_name}-account"
  authentication_method = "IAM_AND_QUICKSIGHT"
  edition              = "ENTERPRISE"
  notification_email   = var.notification_email
}

resource "aws_quicksight_data_source" "gbfs_s3" {
  data_source_id = "${var.environment}-${var.project_name}-s3-source"
  aws_account_id = data.aws_caller_identity.current.account_id
  name           = "GBFS Historical Data"
  type           = "S3"

  parameters {
    s3 {
      manifest_file_location {
        bucket = aws_s3_bucket.gbfs_historical_data.id
        key    = "manifest.json"
      }
    }
  }

  permission {
    actions   = ["quicksight:UpdateDataSourcePermissions", "quicksight:DescribeDataSource", "quicksight:DescribeDataSourcePermissions", "quicksight:PassDataSource", "quicksight:UpdateDataSource", "quicksight:DeleteDataSource"]
    principal = aws_iam_role.quicksight_role.arn
  }
}

# Set up incremental refresh every 5 minutes
resource "aws_quicksight_refresh_schedule" "incremental_refresh" {
  aws_account_id   = data.aws_caller_identity.current.account_id
  dataset_id       = aws_quicksight_data_source.gbfs_s3.data_source_id
  schedule_id      = "IncrementalRefresh"
  refresh_type     = "INCREMENTAL_REFRESH"
  schedule         = "*/5 * * * ? *"  # Every 5 minutes
}

# Create a separate folder for real-time data
resource "aws_s3_bucket_object" "realtime_manifest" {
  bucket  = aws_s3_bucket.gbfs_historical_data.id
  key     = "realtime/manifest.json"
  content = jsonencode({
    fileLocations = [
      {
        URIPrefixes = [
          "s3://${aws_s3_bucket.gbfs_historical_data.id}/realtime/"
        ]
      }
    ],
    globalUploadSettings = {
      format = "JSON",
      delimiter = ",",
      containsHeader = "true"
    }
  })
  content_type = "application/json"
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
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "collector_target" {
  rule      = aws_cloudwatch_event_rule.collector_schedule.name
  target_id = "CollectorLambda"
  arn       = aws_lambda_function.gbfs_collector.arn
}

# Lambda function for real-time data API
resource "aws_lambda_function" "realtime_api" {
  filename      = "../build/realtime.zip"
  function_name    = "${var.environment}-${var.project_name}-realtime-api"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 30

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.gbfs_historical_data.id
      PROVIDERS = jsonencode(var.gbfs_providers)
    }
  }

  tags = {
    Environment = var.environment
  }
}

# API Gateway REST API
resource "aws_api_gateway_rest_api" "realtime" {
  name = "${var.environment}-${var.project_name}-realtime-api"
  
  tags = {
    Environment = var.environment
  }
}

# API Gateway Resource
resource "aws_api_gateway_resource" "realtime" {
  rest_api_id = aws_api_gateway_rest_api.realtime.id
  parent_id   = aws_api_gateway_rest_api.realtime.root_resource_id
  path_part   = "realtime"
}

# API Gateway Method
resource "aws_api_gateway_method" "realtime_get" {
  rest_api_id   = aws_api_gateway_rest_api.realtime.id
  resource_id   = aws_api_gateway_resource.realtime.id
  http_method   = "GET"
  authorization = "NONE"  # Consider adding authorization in production

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET"]
    allow_headers = ["Content-Type", "X-Amz-Date", "Authorization", "X-Api-Key", "X-Amz-Security-Token"]
    max_age      = 300
  }
}

# API Gateway Integration with Lambda
resource "aws_api_gateway_integration" "realtime_lambda" {
  rest_api_id = aws_api_gateway_rest_api.realtime.id
  resource_id = aws_api_gateway_resource.realtime.id
  http_method = aws_api_gateway_method.realtime_get.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.realtime_api.invoke_arn
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "realtime_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.realtime_api.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.realtime.execution_arn}/*/*"
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "realtime" {
  rest_api_id = aws_api_gateway_rest_api.realtime.id

  depends_on = [
    aws_api_gateway_integration.realtime_lambda
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# API Gateway Stage
resource "aws_api_gateway_stage" "realtime" {
  deployment_id = aws_api_gateway_deployment.realtime.id
  rest_api_id   = aws_api_gateway_rest_api.realtime.id
  stage_name    = var.environment
}

# Add CORS configuration
resource "aws_api_gateway_method_response" "cors" {
  rest_api_id = aws_api_gateway_rest_api.realtime.id
  resource_id = aws_api_gateway_resource.realtime.id
  http_method = aws_api_gateway_method.realtime_get.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"      = true
    "method.response.header.Access-Control-Allow-Headers"     = true
    "method.response.header.Access-Control-Allow-Methods"     = true
    "method.response.header.Access-Control-Allow-Credentials" = true
  }
}

resource "aws_api_gateway_integration_response" "cors" {
  rest_api_id = aws_api_gateway_rest_api.realtime.id
  resource_id = aws_api_gateway_resource.realtime.id
  http_method = aws_api_gateway_method.realtime_get.http_method
  status_code = aws_api_gateway_method_response.cors.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"      = "'*'"
    "method.response.header.Access-Control-Allow-Headers"     = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods"     = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Credentials" = "'true'"
  }

  depends_on = [
    aws_api_gateway_method_response.cors
  ]
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

# Lambda function for dashboard API
resource "aws_lambda_function" "dashboard_api" {
  filename         = "lambda_api.zip"
  function_name    = "${var.environment}-${var.project_name}-api"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.gbfs_historical_data.id
    }
  }

  tags = {
    Environment = var.environment
  }
}