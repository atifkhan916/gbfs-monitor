
# S3 bucket for storing historical data
resource "aws_s3_bucket" "gbfs_historical_data" {
  bucket = "${var.project_name}-historical-data"
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.gbfs_historical_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

# DynamoDB table for current state
resource "aws_dynamodb_table" "gbfs_current_state" {
  name           = "${var.project_name}-current-state"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "provider"
  range_key      = "timestamp"

  attribute {
    name = "provider"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# QuickSight resources
resource "aws_quicksight_account_subscription" "quicksight" {
  account_name          = "${var.project_name}-account"
  authentication_method = "IAM_AND_QUICKSIGHT"
  edition              = "ENTERPRISE"
  notification_email   = var.notification_email
}

resource "aws_quicksight_data_source" "s3_source" {
  data_source_id = "${var.project_name}-s3-source"
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

resource "aws_quicksight_data_source" "dynamodb_source" {
  data_source_id = "${var.project_name}-dynamodb-source"
  aws_account_id = data.aws_caller_identity.current.account_id
  name           = "GBFS Current State"
  type           = "AMAZON_DYNAMODB"
  
  parameters {
    dynamic_db {
      table_name = aws_dynamodb_table.gbfs_current_state.name
    }
  }

  permission {
    actions   = ["quicksight:UpdateDataSourcePermissions", "quicksight:DescribeDataSource", "quicksight:DescribeDataSourcePermissions", "quicksight:PassDataSource", "quicksight:UpdateDataSource", "quicksight:DeleteDataSource"]
    principal = aws_iam_role.quicksight_role.arn
  }
}

# IAM role for QuickSight
resource "aws_iam_role" "quicksight_role" {
  name = "${var.project_name}-quicksight-role"

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
  name = "${var.project_name}-quicksight-policy"
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
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:BatchGetItem",
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.gbfs_current_state.arn
        ]
      }
    ]
  })
}


# Lambda function for data collection
resource "aws_lambda_function" "gbfs_collector" {
  filename         = "lambda_collector.zip"
  function_name    = "${var.project_name}-collector"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 300

  environment {
    variables = {
      PROVIDERS = jsonencode(var.gbfs_providers)
      DYNAMODB_TABLE = aws_dynamodb_table.gbfs_current_state.name
      S3_BUCKET = aws_s3_bucket.gbfs_historical_data.id
    }
  }
}

# CloudWatch Event Rule to trigger Lambda
resource "aws_cloudwatch_event_rule" "collector_schedule" {
  name                = "${var.project_name}-collector-schedule"
  description         = "Trigger GBFS data collection every 5 minutes"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "collector_target" {
  rule      = aws_cloudwatch_event_rule.collector_schedule.name
  target_id = "CollectorLambda"
  arn       = aws_lambda_function.gbfs_collector.arn
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period             = "300"
  statistic          = "Sum"
  threshold          = "0"
  alarm_description  = "This metric monitors lambda function errors"
  alarm_actions      = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.gbfs_collector.function_name
  }
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# API Gateway for dashboard data
resource "aws_api_gateway_rest_api" "gbfs_api" {
  name = "${var.project_name}-api"
}

# Lambda function for dashboard API
resource "aws_lambda_function" "dashboard_api" {
  filename         = "lambda_api.zip"
  function_name    = "${var.project_name}-api"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.gbfs_current_state.name
      S3_BUCKET = aws_s3_bucket.gbfs_historical_data.id
    }
  }
}