# IAM authentication to RDS cross-account

*Goal:*  Allow for a BYOC cluster using Redpanda Connect's postgres_cdc connector to authenticating to Aurora Postgres Serverless where Aurora lives in a different account from the Redpanda cluster.

Repdanda will typically live in a separate account from other customer cloud resources.   So for Redpanda Connect to talk to things like Aurora Postgres in a different account using IAM auth, we have some IAM work to do.   First and foremost, we need an IAM Role that allows for rds-db:connect to the database/user.  This role must live in the same account as the Aurora instance.   This role will be assumed by Redpanda Connect, so it will need a trust policy to allow it to trust the RPCN role, and will allow RPCN to assume the dbconnect role.   It will make more sense when you see it in practice.   That RPCN role will also need a policy that allows it to assume the dbconnect role.   Lastly, we'll need to specify in the pipeline config itself the arn of the dbconnect role so it knows exactly what you want it to do.

On an EC2 instance, it is much easier since the EC2 instance can have an IAM role attached, but since BYOC & RPCN on BYOC runs in EKS, it is more complicated, involving IRSA among other way in the weeds details.

```text
┌──────────────────────────────────────────────┐
│ Kubernetes Pod                               │
│ redpanda-connect                             │
│ ServiceAccount: redpanda-connect-pipeline-sa │
│                                              │
│ (no static AWS creds)                        │
└───────────────┬──────────────────────────────┘
                │ projected OIDC token
                │ /var/run/secrets/eks.amazonaws.com/serviceaccount/token
                ▼
┌──────────────────────────────────────────────┐
│ IRSA / Web Identity                          │
│ sts:AssumeRoleWithWebIdentity                │
│                                              │
│ redpanda-connect-pipeline role               │
│ (first STS session, in RP account)           │
└───────────────┬──────────────────────────────┘
                │ sts:AssumeRole
                │ (tag-gated: redpanda_scope_*)
                ▼
┌──────────────────────────────────────────────┐
│ DB-account IAM Role                          │
│ demo-allow_connect_to_aurora-iam-demo-user   │
│ (second STS session, DB account)             │
│                                              │
│ Policy allow: rds-db:connect                 │
│ Resource:                                    │
│ arn:aws:rds-db:REGION:DB_ACCT:               │
│   dbuser:cluster-XXXX/iam_demo_user          │
│ Trust: redpanda-connect-pipeline role        │
│                                              │
└───────────────┬──────────────────────────────┘
                │ aws rds generate-db-auth-token
                │ (host, port, region, username)
                ▼
┌──────────────────────────────────────────────┐
│ Aurora PostgreSQL (Serverless v2)            │
│                                              │
│ Validates IAM token against:                 │
│ - cluster resource ID                        │
│ - DB account                                 │
│ - DB user has rds_iam                        │
│                                              │
│ Authenticates as iam_demo_user               │
└──────────────────────────────────────────────┘
```

---

# Walkthrough

## Pre-requisites

You'll need a Redpanda cluster.   That's it.


## Steps

### 1.  Clone this repo

```bash
git clone .....
cd RPCN-to-Aurora-via-IAM/aws
```

### 2.  Update tfvars

The terraform uses your AWS profile (`~/.aws/config`) to create a new VPC, Aurora Serversless instance, and an IAM role.  It's important that this be in a different AWS account from your Redpanda cluster, which is likely in your default profile via environment variable (`echo $AWS_PROFILE`)

The Aurora security group will need to allow inbound traffic on port 5432 from Redpanda.   In production you would likely use the CIDR range of your Redpanda cluster, but to the sake of simplicity we will create a public Aurora instance and communicate over the public internet.   This means that the traffic to Aurora will be coming from the Redpanda NAT Gateway, the address of which can be found in the Redpanda Cloud UI on the Overview tab.   The Redpanda cluster CIDR is left as an example, but this repo's terraform is not set up to make use of private networking (also would require cross-account VPC peering).

The necessary Redpanda components will be created as well.

### 3.  Run the Aurora terraofrm

The terraform under `aws/` will create the necessary AWS resources 
* new VPC
* Aurora Serverless db
* Redpanda topic
* Redpanda sasl user/password/ACLs
* Repdanda Connect pipeline ==> you'll have to start it manually

```bash
terraform init
terraform apply --auto-approve
```

### 4.  Create database user/objects

```bash
psql -h $(terraform output -raw db_cluster_endpoint) \
     -p 5432 \
     -U $(terraform output -raw db_username) \
     -d $(terraform output -raw db_name) \
     -f cdc_setup.sql 

```

It will prompt you for the password, which is postgres (unless you changed it).   Once authenticated, it will execute the contents of `cdc_setup.sql`

### 5.  Verify the pipeline is running ok

We can use `rpk` to consume the connect logs topic.  If your cluster has other running pipelines then this topic could be noisy.   But you're looking for only messages specifically for your new pipeline, so we can just grep for those messages.

```bash
rpk topic consume __redpanda.connect.logs --offset start | grep $(terraform output -raw rpcn_pipeline_id)
```

Really we're looking for ERROR messages, but often times seeing the whole stream is helpful in troubleshooting.

```bash
rpk topic consume __redpanda.connect.logs --offset start | grep $(terraform output -raw rpcn_pipeline_id) | grep 'ERROR'
```

If you see the `postgres_cdc` input go active, then you're probalby in good shape.


### 6.  Insert rows into the table 

It is probably adviseable to first validate that your pipeline is running error-free

```bash
psql -h $(terraform output -raw db_cluster_endpoint) \
     -p 5432 \
     -U $(terraform output -raw db_username) \
     -d $(terraform output -raw db_name) \
     -f insert_data.sql 

```

### 7.  Consume the topic

```bash
rpk topic consume $(terraform output -raw cdc_output_topic) --offset start
```

You should see a stream of messages corresponding to the inserts you ran into the database in step #6.   "Advanced" users might have one window consuming the topic while a different window runs the database inserts so you can see the stream flow in real time.

### 8.  Tear it down

```
terraform destroy --auto-approve
```

---
## IAM roles

This section describes the what & why for the IAM roles needed to make this work.   It boils down to 2 simple things:  an IAM role owned by the Aurora acct that allows connect, and then a policy on the Redpanda side that allows RPCN to assume that database connect role.   

### db connect role 

#### Permissions

In the account that owns the database, you will need an IAM role with permissions to allow it to connect to the database, but the resource for this role isn't the _database_, it's actually a user within the database.   You can find part of this in the console for your Regional Cluster (not the writer instance) under Configuration > Resource ID.   It will look like `cluster-X4BNAQDEZCAUGHTITYK7B6YCAQ`.   You will also specify a database user as part of the resource.  It doesn't have to be created _yet_, but it will be the user RPCN connects as.  Again, this role must live in the same AWS account as where Aurora lives.


Name it `rpcn-demo-xaccount-rds-connect-role`

```json
{
    "Statement": [
        {
            "Action": "rds-db:connect",
            "Effect": "Allow",
            "Resource": "arn:aws:rds-db:us-east-2:<Aurora PG AWS Acct ID>:dbuser:cluster-X4BNAQDEZCAUGHTITYK7B6YCAQ/iam_demo_user"
        }
    ],
    "Version": "2012-10-17"
```

The resource ID of your Aurora instance can also be found via the AWS cli.  Note that if you're using the terraform from this repo, you will need to specify the profile you used to deploy Aurora (se_demo for me).

```bash
aws rds describe-db-clusters \
  --query "DBClusters[?DBClusterIdentifier=='demo-aurora-pg'].[DBClusterIdentifier,DbClusterResourceId,Endpoint]" \
  --output table --profile se_demo
```

#### Trust Policy

The dbconnect role will be assumed by RPCN, so we have to allow it to trust the role that RPCN will be using to assume the dbconnect role.  The principal is the arn of that RPCN role, which was created when the Redpanda Cluster was created and will be owned by the account where Redpanda is deployed.   The role itself is named like `redpanda-<Your Redpanda Cluster ID>-redpanda-connect-pipeline`.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::<Redpanda AWS Acct ID>:role/redpanda-curl3eo533cmsnt23dv0-redpanda-connect-pipeline"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
```

#### Tagging (important!)

The RPCN role specifies a condition, which requires that the dbconnect role have a specific tag:
key: `redpanda_scope_redpanda_connect"`
value: `true`

If you do not include this tag, the role assumption will fail.


### Redpanda Connect Role

As mentioned above, this role is created when your Redpanda cluster is created.   If your cluster had cluster ID `curl3eo533cmsnt23dv0` then your role would be named `redpanda-curl3eo533cmsnt23dv0-redpanda-connect-pipeline`.  It is vital that we don't change the policies attached to this role.   Out of the box there is a policy that allows it to read AWS secrets, and a trust policy that involves IRSA, OIDC, federated identities...it complex.  The good news is you don't need to worry about this.   There may also be another policy in this role (but there might not be, depends on how the cloud team ends up implementing this), but if we want to be explicit, we can create a new policy for this role.   It is important to understand that if we change the existing policies those changes will be reverted by the Redpanda reconciliation process.   But _adding a policy_ won't be subject to that.   So we will need to create a policy that allows this role to assume the dbconnect role.   It should look very much just like this, and it should be attached to the RPCN role.

Note:  the terraform in this repo will not generate this policy, nor will it attach it to the RPCN role.  It is left as an exercise to the reader (for now).

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole"
            ],
            "Resource": [
                "arn:aws:iam::<Aurora PG AWS Acct ID>:role/rpcn-demo-xaccount-rds-connect-role"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:ResourceTag/redpanda_scope_redpanda_connect": "true"
                }
            }
        }
    ]
}
```






