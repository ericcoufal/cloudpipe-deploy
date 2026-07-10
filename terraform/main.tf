# CloudPipe infrastructure - Terraform version.
# Same architecture as infrastructure/template.yaml (deploy ONE or the
# other, not both - they'd fight over the same bucket name):
# private S3 bucket -> CloudFront (OAC, HTTPS) -> least-privilege deploy user.

# Who am I? Used to build the unique bucket name and IAM ARNs.
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------
# S3 bucket for the website files.
# WHY private: all traffic goes through CloudFront (HTTPS, caching,
# single access-control point). Note how Terraform splits what CFN
# nests in one resource - each aspect (access block, encryption,
# policy) is its own resource. More verbose here, but each piece is
# independently manageable.
# ---------------------------------------------------------------
resource "aws_s3_bucket" "website" {
  bucket = "${var.project_name}-website-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "website" {
  bucket = aws_s3_bucket.website.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------
# Origin Access Control: how CloudFront signs its requests to S3.
# (Modern replacement for the legacy Origin Access Identity.)
# ---------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "website" {
  name                              = "${var.project_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ---------------------------------------------------------------
# CloudFront distribution: HTTPS + global edge caching in front of
# the private bucket.
# ---------------------------------------------------------------
resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  comment             = "${var.project_name} website"
  default_root_object = "index.html"
  http_version        = "http2"
  price_class         = "PriceClass_100" # US/EU edges only - local-business audience, cheapest tier

  origin {
    origin_id                = "S3Origin"
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
  }

  default_cache_behavior {
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed "CachingOptimized" policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # OAC-fronted S3 returns 403 for missing keys; map 403/404 to the
  # index page for clean errors (and SPA support later).
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # swap for an ACM cert when adding a custom domain
  }
}

# ---------------------------------------------------------------
# Bucket policy: ONLY our CloudFront distribution may read objects.
# The SourceArn condition pins it to this exact distribution.
# ---------------------------------------------------------------
data "aws_iam_policy_document" "allow_cloudfront" {
  statement {
    sid     = "AllowCloudFrontRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.website.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.website.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id
  policy = data.aws_iam_policy_document.allow_cloudfront.json

  # The public access block must exist first, or AWS can reject the
  # policy write. Terraform usually infers order from references, but
  # there's no reference between these two - so we state it explicitly.
  depends_on = [aws_s3_bucket_public_access_block.website]
}

# ---------------------------------------------------------------
# IAM user for GitHub Actions - least privilege: sync this bucket,
# invalidate this distribution, nothing else.
#
# WHY create access keys via CLI and not in Terraform: an
# aws_iam_access_key resource stores the SECRET in the state file in
# plaintext. Keeping secrets out of state is a standard practice
# (and a good interview answer).
# ---------------------------------------------------------------
resource "aws_iam_user" "deploy" {
  name = "${var.project_name}-github-actions"
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid    = "SyncWebsiteFiles"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObject",
    ]
    resources = ["${aws_s3_bucket.website.arn}/*"]
  }

  statement {
    sid       = "ListBucketForSync"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.website.arn]
  }

  statement {
    sid       = "InvalidateCache"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.website.arn]
  }
}

resource "aws_iam_user_policy" "deploy" {
  name   = "DeployWebsite"
  user   = aws_iam_user.deploy.name
  policy = data.aws_iam_policy_document.deploy.json
}
