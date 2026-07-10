variable "project_name" {
  description = "Prefix used for naming resources."
  type        = string
  default     = "cloudpipe"
}

variable "aws_region" {
  description = "Region for the S3 bucket. (CloudFront itself is global.)"
  type        = string
  default     = "us-east-1"
}
