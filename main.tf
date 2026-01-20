terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }

    redpanda = {
      source  = "redpanda-data/redpanda"
      version = "~> 1.5.0"
    }

  }
}

provider "aws" {
  region = var.region
  profile = var.aws_profile 
}

provider "redpanda" {
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "redpanda_cluster" "byoc" {
  id = var.redpanda_cluster_id
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Two /26 public subnets carved from the /24
  public_subnet_cidrs = [
    cidrsubnet(var.vpc_cidr, 2, 0),
    cidrsubnet(var.vpc_cidr, 2, 1),
  ]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

data "http" "home_ip" {
  url = "https://api.ipify.org"
}

locals {
  home_ip_cidr = "${chomp(data.http.home_ip.response_body)}/32"
}


resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Allow Postgres from home IP"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Allow traffic to Postgres from home/Redpanda"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.home_ip_cidr, var.redpanda_cidr]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-db-sg"
  }
}

resource "aws_db_subnet_group" "db" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = aws_subnet.public[*].id

  tags = {
    Name = "${var.name_prefix}-db-subnets"
  }
}

resource "aws_rds_cluster_parameter_group" "aurora_pg17" {
  name   = "${var.name_prefix}-aurora-pg17-cluster-pg"
  family = "aurora-postgresql17"

  # Require SSL
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Enable logical replication
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Enable IAM auth for replication connections
  parameter {
    name         = "rds.iam_auth_for_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Reasonable starting values; tune for your workload
  parameter {
    name         = "max_replication_slots"
    value        = "10"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = "10"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.name_prefix}-aurora-pg17-cluster-pg"
  }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.name_prefix}-aurora-pg"

  engine         = "aurora-postgresql"
  engine_version = var.engine_version

  # Serverless v2 uses engine_mode = "provisioned" + serverlessv2_scaling_configuration
  engine_mode = "provisioned" # :contentReference[oaicite:4]{index=4}

  serverlessv2_scaling_configuration {
    min_capacity = var.serverlessv2_min_acu
    max_capacity = var.serverlessv2_max_acu
  }

  database_name   = var.db_name
  master_username = var.db_username
  master_password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]

  storage_encrypted = true

  # IAM DB authentication (tokens) enabled at the cluster level :contentReference[oaicite:5]{index=5}
  iam_database_authentication_enabled = true

  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora_pg17.name

  skip_final_snapshot = true
  deletion_protection = false

  tags = {
    Name = "${var.name_prefix}-aurora-pg"
  }
}

resource "aws_rds_cluster_instance" "aurora_instance" {
  identifier         = "${var.name_prefix}-aurora-pg-1"
  cluster_identifier = aws_rds_cluster.aurora.id

  engine         = aws_rds_cluster.aurora.engine
  engine_version = aws_rds_cluster.aurora.engine_version

  instance_class = "db.serverless"
  publicly_accessible = true

  tags = {
    Name = "${var.name_prefix}-aurora-pg-1"
  }
}


############
# IAM role
############

data "aws_caller_identity" "current" {}


# Construct the actual Repdanda Connect pipeline role ARN
locals {
  trusted_principal_role_arn = "arn:aws:iam::${var.redpanda_aws_acct_id}:role/redpanda-${var.redpanda_cluster_id}-redpanda-connect-pipeline"
}

# Role that will be assumed by the principal you pass in via tfvars
resource "aws_iam_role" "allow_connect_to_aurora_iam_demo_user" {
  name = "${var.name_prefix}-allow_connect_to_aurora-iam-demo-user"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeFromTrustedPrincipal"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          AWS = local.trusted_principal_role_arn
        }
      }
    ]
  })

  tags = {
    redpanda_scope_redpanda_connect = "true"
  }
}

# Permission to connect as database user given by var.iam_auth_user
# IMPORTANT: rds-db:connect uses the *cluster* resource_id: aws_rds_cluster_instance.<...>.resource_id
resource "aws_iam_role_policy" "allow_aurora_iam_demo_user_connect_policy" {
  name = "${var.name_prefix}-allow_aurora-iam-demo-user-connect_policy"
  role = aws_iam_role.allow_connect_to_aurora_iam_demo_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowIamAuthToAuroraAsIamDemoUser"
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_rds_cluster.aurora.cluster_resource_id}/${var.iam_auth_user}"
        ]
      }
    ]
  })
}


################
# Redpanda stuff
################

resource "redpanda_topic" "topic" {
  name               = "rpcn_iam_auth_topic_test"
  partition_count    = 3
  replication_factor = 3
  allow_deletion     = "true"
  cluster_api_url    = data.redpanda_cluster.byoc.cluster_api_url
}

resource "redpanda_user" "app" {
  name            = var.rp_sasl_user
  password        = var.rp_sasl_password
  mechanism       = "scram-sha-256"
  cluster_api_url = data.redpanda_cluster.byoc.cluster_api_url

  # Optional, but commonly set to avoid “dangling state” issues if the cluster is unreachable
  allow_deletion = true
}

resource "redpanda_acl" "topic_write" {
  cluster_api_url = data.redpanda_cluster.byoc.cluster_api_url

  principal          = "User:${var.rp_sasl_user}"
  host               = "*"
  resource_type      = "TOPIC"
  resource_name      = redpanda_topic.topic.name
  resource_pattern_type = "LITERAL"

  operation       = "WRITE"
  permission_type = "ALLOW"
  allow_deletion  = true
}

resource "redpanda_acl" "topic_describe_for_produce" {
  cluster_api_url = data.redpanda_cluster.byoc.cluster_api_url

  principal          = "User:${var.rp_sasl_user}"
  host               = "*"
  resource_type      = "TOPIC"
  resource_name      = redpanda_topic.topic.name
  resource_pattern_type = "LITERAL"

  operation       = "DESCRIBE"
  permission_type = "ALLOW"
  allow_deletion  = true
}

locals {
  pipeline_yaml = templatefile("${path.module}/pipeline.yaml.tmpl", {
    iam_auth_user        = var.iam_auth_user
    db_cluster_endpoint  = aws_rds_cluster.aurora.endpoint
    db_name              = var.db_name
    aws_region           = var.region
    iam_db_auth_role_arn = aws_iam_role.allow_connect_to_aurora_iam_demo_user.arn
    topic                = redpanda_topic.topic.name
    sasl_username        = var.rp_sasl_user
    sasl_password        = var.rp_sasl_password
  })
}

resource "local_file" "pipeline_yaml" {
  filename        = "${path.module}/generated_pipeline.yaml"
  content         = local.pipeline_yaml
  file_permission = "0600"
}

resource "redpanda_pipeline" "pipeline" {
  cluster_api_url = data.redpanda_cluster.byoc.cluster_api_url
  display_name    = "test x-account IAM auth to RDS"
  description     = "Redpanda Connect pipeline using IAM authentication to pull CDC from an Aurora instance in a different AWS account."
  state           = "running"
  allow_deletion  = "true"

  #config_yaml = file("${path.module}/generated_pipeline.yaml")
  config_yaml = local_file.pipeline_yaml.content

  resources = {
    memory_shares = "256Mi"
    cpu_shares    = "200m"
  }

  depends_on = [redpanda_topic.topic]
}

locals {
  x_account_policy_json = templatefile("${path.module}/x-account-rds-iam-policy.json.tmpl", {
    db_connect_role_arn = aws_iam_role.allow_connect_to_aurora_iam_demo_user.arn
  })
}

resource "local_file" "iam_policy_json" {
  filename        = "${path.module}/generated_x-account-rds-iam-policy.json"
  content         = local.x_account_policy_json
  file_permission = "0600"
}

output "db_cluster_endpoint" {
  value = aws_rds_cluster.aurora.endpoint
}

output "db_name" {
  value = var.db_name
}

output "db_username" {
  value = var.db_username
}

output "aurora_instance_resource_id" {
  value = aws_rds_cluster.aurora.cluster_resource_id
}

output "iam_db_auth_role_arn" {
  value = aws_iam_role.allow_connect_to_aurora_iam_demo_user.arn
}

output "rpcn_pipeline_id" {
  value = redpanda_pipeline.pipeline.id
}

output "cdc_output_topic" {
  value = redpanda_topic.topic.name
}

