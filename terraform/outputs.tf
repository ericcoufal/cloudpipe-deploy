# Same outputs as the CloudFormation template - these feed the GitHub secrets.

output "bucket_name" {
  description = "S3 bucket holding the website files (use as S3_BUCKET secret)"
  value       = aws_s3_bucket.website.id
}

output "distribution_id" {
  description = "CloudFront distribution ID (use as CLOUDFRONT_DISTRIBUTION_ID secret)"
  value       = aws_cloudfront_distribution.website.id
}

output "website_url" {
  description = "Public URL of the website"
  value       = "https://${aws_cloudfront_distribution.website.domain_name}"
}

output "deploy_user_name" {
  description = "IAM user - create access keys for this user for GitHub Actions"
  value       = aws_iam_user.deploy.name
}
