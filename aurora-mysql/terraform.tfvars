region       = "us-east-2"
name_prefix  = "demo-mysql"
aws_profile  = "se_demo"  # the name of the aws profile where you want to deploy aurora

vpc_cidr = "10.211.0.0/24"  # CIDR range of the new VPC where RDS will deploy

# Allowing access to RDS:
   # if your database is private (most likely) you would first peer the networks, and then add a SG rule to allow traffic from the Redpanda CIDR
   # if your database is public (i.e. this terraform example), terraform  will add an SG rule to allow traffic from the Redpanda NAT Gateway
redpanda_cidr = "3.139.175.89/32" # example for allowing public access via Redpanda NAT Gateway
#redpanda_cidr = "10.0.0.0/16"    # example for allowing Redpanda VPC access via private networking

# These 2 variables are required in order to construct the name of the RPCN role that your database connect role will need to trust.
redpanda_aws_acct_id     = "861276079005"            # the AWS account ID where your repdanda cluster is deployed
redpanda_cluster_id      = "curl3eo533cmsnt23dv0"    # this will be YOUR cluster ID

rp_sasl_user      = "demo_mysql_iam_sasl_user"
rp_sasl_password  = "demo_iam_sasl_password"


db_name       = "demo_db"
db_username   = "admin"
db_password   = "admin1234"
iam_auth_user = "iam_demo_user"

engine_version       = "8.0.mysql_aurora.3.10.3"
serverlessv2_min_acu = 0.5
serverlessv2_max_acu = 2
az_count             = 2


