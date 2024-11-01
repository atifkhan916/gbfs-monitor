# S3 and CloudFront for hosting React SPA
resource "aws_s3_bucket" "website" {
  bucket = "${var.environment}-${var.project_name}-website"
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "website" {
  bucket = aws_s3_bucket.website.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_identity" "website" {
  comment = "OAI for ${var.environment}-${var.project_name} website"
}

resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontOAI"
        Effect    = "Allow"
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.website.iam_arn
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.website.arn}/*"
      }
    ]
  })
}

resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id   = "S3-${aws_s3_bucket.website.bucket}"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.website.cloudfront_access_identity_path
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.website.bucket}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Environment = var.environment
  }
}

# DynamoDB Tables
resource "aws_dynamodb_table" "bike_stats" {
  name           = "${var.environment}-${var.project_name}-bike-stats"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "provider_id"
  range_key      = "timestamp"

  attribute {
    name = "provider_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  attribute {
    name = "date"
    type = "S"
  }

  global_secondary_index {
    name            = "DateIndex"
    hash_key        = "date"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # Enable TTL
  ttl {
    attribute_name = "expiry_time"
    enabled        = true
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_dynamodb_table" "websocket_connections" {
  name           = "${var.environment}-${var.project_name}-connections"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "connection_id"

  attribute {
    name = "connection_id"
    type = "S"
  }

  tags = {
    Environment = var.environment
  }
}

# Lambda function for cleaning up old data
resource "aws_lambda_function" "cleanup" {
  filename         = "../build/cleanup.zip"
  function_name    = "${var.environment}-${var.project_name}-cleanup"
  role            = aws_iam_role.cleanup_lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 300
  memory_size     = 256
  source_code_hash = filebase64sha256("../build/cleanup.zip")

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.bike_stats.name
      RETENTION_DAYS = "5"
      PROVIDERS    = jsonencode(var.gbfs_providers)
    }
  }

  tags = {
    Environment = var.environment
  }
}

# IAM role for cleanup Lambda
resource "aws_iam_role" "cleanup_lambda_role" {
  name = "${var.environment}-${var.project_name}-cleanup-role"

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
}

# IAM policy for cleanup Lambda
resource "aws_iam_role_policy" "cleanup_lambda_policy" {
  name = "${var.environment}-${var.project_name}-cleanup-policy"
  role = aws_iam_role.cleanup_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:DeleteItem",
          "dynamodb:BatchWriteItem"
        ]
        Resource = [
          aws_dynamodb_table.bike_stats.arn,
          "${aws_dynamodb_table.bike_stats.arn}/index/*"
        ]
      }
    ]
  })
}

# CloudWatch Event for cleanup Lambda (runs daily)
resource "aws_cloudwatch_event_rule" "cleanup_schedule" {
  name                = "${var.environment}-${var.project_name}-cleanup-schedule"
  description         = "Schedule for cleaning up old bike stats data"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "cleanup_target" {
  rule      = aws_cloudwatch_event_rule.cleanup_schedule.name
  target_id = "CleanupLambda"
  arn       = aws_lambda_function.cleanup.arn
}

resource "aws_lambda_permission" "allow_cleanup_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cleanup_schedule.arn
}

# API Gateway WebSocket API
resource "aws_apigatewayv2_api" "websocket" {
  name                       = "${var.environment}-${var.project_name}-websocket"
  protocol_type             = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}


resource "aws_apigatewayv2_integration" "connect" {
  api_id                    = aws_apigatewayv2_api.websocket.id
  integration_type          = "AWS_PROXY"
  integration_uri          = aws_lambda_function.websocket_handler.invoke_arn
  content_handling_strategy = "CONVERT_TO_TEXT"
  credentials_arn         = aws_iam_role.apigw_role.arn
  description            = "Connect integration"
  integration_method     = "POST"
  passthrough_behavior   = "WHEN_NO_MATCH"
}

resource "aws_apigatewayv2_integration" "disconnect" {
  api_id                    = aws_apigatewayv2_api.websocket.id
  integration_type          = "AWS_PROXY"
  integration_uri          = aws_lambda_function.websocket_handler.invoke_arn
  content_handling_strategy = "CONVERT_TO_TEXT"
  credentials_arn         = aws_iam_role.apigw_role.arn
  description            = "Disconnect integration"
  integration_method     = "POST"
  passthrough_behavior   = "WHEN_NO_MATCH"
}

resource "aws_apigatewayv2_integration" "default" {
  api_id                    = aws_apigatewayv2_api.websocket.id
  integration_type          = "AWS_PROXY"
  integration_uri          = aws_lambda_function.websocket_handler.invoke_arn
  content_handling_strategy = "CONVERT_TO_TEXT"
  credentials_arn         = aws_iam_role.apigw_role.arn
  description            = "Default integration"
  integration_method     = "POST"
  passthrough_behavior   = "WHEN_NO_MATCH"
}

resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.connect.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.disconnect.id}"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.default.id}"
}

# IAM Role for API Gateway
resource "aws_iam_role" "apigw_role" {
  name = "${var.environment}-${var.project_name}-apigw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda Functions
resource "aws_lambda_function" "collector" {
  filename         = "../build/collector.zip"
  function_name    = "${var.environment}-${var.project_name}-collector"
  role            = aws_iam_role.collector_lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 300
  memory_size     = 256
  source_code_hash = filebase64sha256("../build/collector.zip")

  environment {
    variables = {
      DYNAMODB_TABLE  = aws_dynamodb_table.bike_stats.name
      PROVIDERS       = jsonencode(var.gbfs_providers)
    }
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_lambda_function" "websocket_handler" {
  filename         = "../build/websocket.zip"
  function_name    = "${var.environment}-${var.project_name}-websocket"
  role            = aws_iam_role.websocket_lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 30
  source_code_hash = filebase64sha256("../build/websocket.zip")

  environment {
    variables = {
      CONNECTIONS_TABLE = aws_dynamodb_table.websocket_connections.name
      BIKE_STATS_TABLE = aws_dynamodb_table.bike_stats.name
    }
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "apigw_policy" {
  name = "${var.environment}-${var.project_name}-apigw-policy"
  role = aws_iam_role.apigw_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.websocket_handler.arn
        ]
      }
    ]
  })

  depends_on = [ aws_lambda_function.websocket_handler ]
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "websocket" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.websocket_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.websocket.execution_arn}/*"
}

resource "aws_apigatewayv2_deployment" "websocket" {
  api_id = aws_apigatewayv2_api.websocket.id

  depends_on = [
    aws_apigatewayv2_route.connect,
    aws_apigatewayv2_route.disconnect,
    aws_apigatewayv2_route.default
  ]
}

resource "aws_apigatewayv2_stage" "websocket" {
  api_id = aws_apigatewayv2_api.websocket.id
  name   = var.environment
  deployment_id = aws_apigatewayv2_deployment.websocket.id

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
    detailed_metrics_enabled = true
  }
}

# IAM Roles and Policies
resource "aws_iam_role" "collector_lambda_role" {
  name = "${var.environment}-${var.project_name}-collector-role"

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
}

resource "aws_iam_role_policy" "collector_lambda_policy" {
  name = "${var.environment}-${var.project_name}-collector-policy"
  role = aws_iam_role.collector_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.bike_stats.arn
      }
    ]
  })
}

resource "aws_iam_role" "websocket_lambda_role" {
  name = "${var.environment}-${var.project_name}-websocket-role"

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
}

resource "aws_iam_role_policy" "websocket_lambda_policy" {
  name = "${var.environment}-${var.project_name}-websocket-policy"
  role = aws_iam_role.websocket_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.websocket_connections.arn,
          aws_dynamodb_table.bike_stats.arn,
          "${aws_dynamodb_table.bike_stats.arn}/index/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "execute-api:ManageConnections"
        ]
        Resource = "${aws_apigatewayv2_api.websocket.execution_arn}/${var.environment}/*"
      }
    ]
  })
}

# CloudWatch Event for Collector Lambda
resource "aws_cloudwatch_event_rule" "collector_schedule" {
  name                = "${var.environment}-${var.project_name}-collector-schedule"
  description         = "Schedule for GBFS data collection"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "collector_target" {
  rule      = aws_cloudwatch_event_rule.collector_schedule.name
  target_id = "CollectorLambda"
  arn       = aws_lambda_function.collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.collector_schedule.arn
}

resource "aws_cloudwatch_log_group" "collector" {
  name              = "/aws/lambda/${aws_lambda_function.collector.function_name}"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "websocket" {
  name              = "/aws/lambda/${aws_lambda_function.websocket_handler.function_name}"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "cleanup" {
  name              = "/aws/lambda/${aws_lambda_function.cleanup.function_name}"
  retention_in_days = 1
}

resource "aws_iam_role_policy" "lambda_logging" {
  for_each = {
    collector = aws_iam_role.collector_lambda_role.id
    websocket = aws_iam_role.websocket_lambda_role.id
    cleanup   = aws_iam_role.cleanup_lambda_role.id
  }

  name = "${var.environment}-${var.project_name}-${each.key}-logs"
  role = each.value

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

output "websocket_url" {
  value = "wss://${aws_apigatewayv2_api.websocket.id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
  description = "WebSocket URL for frontend connection"
}


# Output the cloudfront_distribution_id for the frontend
output "cloudfront_distribution_id" {
  value = "${aws_cloudfront_distribution.website.id}"
}

# Output the cloudfront_distribution_id for the frontend
output "website_s3_bucket_name" {
  value = "${aws_s3_bucket.website.id}"
}
