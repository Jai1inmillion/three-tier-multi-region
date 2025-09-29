terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws",
      version = "~> 5.57"
    }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
provider "aws" { region = var.primary_region }

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
}
