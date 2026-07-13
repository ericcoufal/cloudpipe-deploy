# Pin versions so the config behaves the same on every machine and in CI.
# WHY: unpinned providers are how "it worked yesterday" bugs happen
# a new provider major version can change resource behavior.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # any 5.x, never 6.x without a deliberate upgrade
    }
  }

  # STATE: by default Terraform writes terraform.tfstate to this folder.
  # Fine for learning. For a team/production setup you'd use a remote
  # backend so state is shared, locked, and not on one laptop:
  #
  # backend "s3" {
  #   bucket       = "my-terraform-state-bucket"
  #   key          = "cloudpipe/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true   # S3-native state locking (Terraform >= 1.10)
  # }
  #
  # Takeaway: state management is THE key difference from
  # CloudFormation, where AWS stores state for you. Terraform's state
  # file maps your config to real resource IDs, lose it or corrupt it
  # and Terraform no longer knows what it manages.
}

provider "aws" {
  region = var.aws_region
}
