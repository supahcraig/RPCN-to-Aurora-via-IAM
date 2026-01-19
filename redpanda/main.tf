terraform {
  required_providers {
    redpanda = {
      source  = "redpanda-data/redpanda"
      version = "~> 1.5.0"
    }
  }
}

provider "redpanda" {
}


data "redpanda_cluster" "byoc" {
  id = var.redpanda_cluster_id
}


resource "redpanda_topic" "topic" {
  name               = "rpcn_iam_auth_topic_test"
  partition_count    = 3
  replication_factor = 3
  allow_deletion     = "true"
  cluster_api_url    = data.redpanda_cluster.byoc.cluster_api_url
}

resource "redpanda_pipeline" "pipeline" {
  cluster_api_url = data.redpanda_cluster.byoc.cluster_api_url
  display_name    = "test x-account IAM auth to RDS"
  description     = "Redpanda Connect pipeline using IAM authentication to pull CDC from an Aurora instance in a different AWS account."
  state           = "stopped"
  allow_deletion  = "true"

  config_yaml = file("${path.module}/pipeline.yaml")

  resources = {
    memory_shares = "256Mi"
    cpu_shares    = "200m"
  }

}

