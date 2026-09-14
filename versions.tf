terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.97"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Bucket e região vêm de -backend-config, pois dependem da conta de quem executa.
  backend "s3" {
    key          = "infra-k8s/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
