# IAM authentication to RDS cross-account

**Goal:**  Allow for a BYOC cluster using Redpanda Connect's postgres_cdc connector to authenticate to Aurora Postgres Serverless where Aurora lives in a different account from the Redpanda cluster.

**Estimated time needed:** 10 minutes, ~7 of which is waiting for Aurora to come up.

**Pre-requisites:** You'll need a Redpanda BYOC cluster.   That's it.

---

Repdanda will typically live in a separate account from other customer cloud resources.   So for Redpanda Connect to talk to things like Aurora Postgres in a different account using IAM auth, we have some IAM work to do.   First and foremost, we need an IAM Role that allows for rds-db:connect to the database/user.  This role must live in the same account as the Aurora instance.   This role will be assumed by Redpanda Connect, so it will need a trust policy to allow it to trust the RPCN role, and will allow RPCN to assume the dbconnect role.   It will make more sense when you see it in practice.   That RPCN role will also need a policy that allows it to assume the dbconnect role, which _may_ be provided by Redpanda (depending on the specific Redpanda release).   Lastly, we'll need to specify in the pipeline config itself the arn of the dbconnect role so it knows exactly what you want it to do.

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

You'll need a Redpanda BYOC cluster.   That's it.


## Steps

### 1.  Clone this repo

```bash
git clone https://github.com/supahcraig/RPCN-to-Aurora-via-IAM.git
cd RPCN-to-Aurora-via-IAM
```

### 2.  Update tfvars

The terraform uses your AWS profile (`~/.aws/config`) to create a new VPC, Aurora Serversless instance, and an IAM role.  It's important that this be in a different AWS account from your Redpanda cluster, which is likely in your default profile via environment variable (`echo $AWS_PROFILE`)

The Aurora security group will need to allow inbound traffic on port 5432 from Redpanda.   In production you would likely use the CIDR range of your Redpanda cluster, but to the sake of simplicity we will create a public Aurora instance and communicate over the public internet.   This means that the traffic to Aurora will be coming from the Redpanda NAT Gateway, the address of which can be found in the Redpanda Cloud UI on the Overview tab.   The Redpanda cluster CIDR is left as an example, but this repo's terraform is not set up to make use of private networking (also would require cross-account VPC peering).

The necessary Redpanda components will be created as well.

<details>
<summary> 
Side Quest:  find your NAT Gateway IP
</summary>

First set a variable for your Redpanda Cluster ID:

```bash
RP_CLUSTER_ID=curl3eo533cmsnt23dv0
```

Then call the Repdana Cloud API to fetch the NAT Gateway IP.

```bash
export AUTH_TOKEN=$(curl -s --request POST \
  --url 'https://auth.prd.cloud.redpanda.com/oauth/token' \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data grant_type=client_credentials \
  --data client_id="${REDPANDA_CLIENT_ID}" \
  --data client_secret="${REDPANDA_CLIENT_SECRET}" \
  --data audience=cloudv2-production.redpanda.cloud | jq -r '.access_token')

curl -s -X GET "https://api.cloud.redpanda.com/v1/clusters/${RP_CLUSTER_ID}" \
  -H "accept: application/json" \
  -H "content-type: application/json" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" | jq .cluster.nat_gateways

```

Should return output like this:

```json
[
  "3.139.175.89"
]
```
</details>


### 3.  Run the Aurora/Redpanda terraofrm

The terraform will create the necessary AWS & Redpanda resources 
* new VPC
* Aurora Serverless db
* Redpanda topic
* Redpanda sasl user/password/ACLs
* Repdanda Connect pipeline ==> the pipeline will start it automatically

<details>
<summary>Aurora Postgres</summary>
Postgres is currently run out of the project root.
</details>
<details>
<summary>Aurora MySQL</summary>
```bash
cd aurora-mysql
```
</details>

```bash
terraform init
terraform apply --auto-approve
```

The RDS spin up is the longest step by far, which should take 7ish minutes.

### 4.  Create database user/objects

<details>
<summary>Aurora Postgres</summary>
```bash
psql -h $(terraform output -raw db_cluster_endpoint) \
     -p 5432 \
     -U $(terraform output -raw db_username) \
     -d $(terraform output -raw db_name) \
     -f postgres_cdc_setup.sql 

```

It will prompt you for the password, which is postgres (unless you changed it in tfvars).   Once authenticated, it will execute the contents of `cdc_setup.sql`
</details>

<details>
<summary>Aurora MySQL</summary>
```bash
mysql -h $(terraform output -raw db_cluster_endpoint) \
-P 3306 \
-u $(terraform output -raw db_username) \
-p $(terraform output -raw db_name) < mysql_cdc_setup.sql

```
</details>

### 5.  Verify the pipeline is running ok

We can use `rpk` to consume the connect logs topic.  If your cluster has other running pipelines then this topic could be noisy.   But you're looking for only messages specifically for your new pipeline, so we can just grep for those messages based on the pipeline ID.

```bash
rpk topic consume __redpanda.connect.logs --offset end | grep $(terraform output -raw rpcn_pipeline_id)
```

Really we're looking for ERROR messages, but often times seeing the whole stream is helpful in troubleshooting. 

If you see the `postgres_cdc` input go active, then you're probalby in good shape.

```bash
rpk topic consume __redpanda.connect.logs --offset end | grep $(terraform output -raw rpcn_pipeline_id) | grep 'ERROR'
```

You may see a few error messages as the pipeline is becoming active.  If there is a steady flow of errors then you will need to troubleshoot.  But pretty quickly the logs topic will become rather idle, indicating that we can safely move to the next step.

If you see the `postgres_cdc` input go active, then you're probalby in good shape.


### 6.  Insert rows into the table 

<details>
<summary>Aurora Postgres</summary>
<details>
```bash
psql -h $(terraform output -raw db_cluster_endpoint) \
     -p 5432 \
     -U $(terraform output -raw db_username) \
     -d $(terraform output -raw db_name) \
     -f postgres_insert.sql 

```
</details>

<details>
<summary>Aurora MySQL</summary>
```bash
mysql -h $(terraform output -raw db_cluster_endpoint) \
-P 3306 \
-u $(terraform output -raw db_username) \
-p $(terraform output -raw db_name) < mysql_insert.sql

```
</details>

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


Name the IAM role `demo-allow_connect_to_aurora-iam-demo-user`

```json
{
    "Statement": [
        {
            "Action": "rds-db:connect",
            "Effect": "Allow",
            "Resource": "arn:aws:rds-db:us-east-2:<Aurora PG AWS Acct ID>:dbuser:<Aurora cluster Endpoint>/iam_demo_user"
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
                "AWS": "arn:aws:iam::<Redpanda AWS Acct ID>:role/redpanda-<Redpanda Cluster ID>-redpanda-connect-pipeline"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
```

#### Tagging (important!)

The RPCN role specifies a condition, which requires that the dbconnect role have a specific tag:
| Key | Value |
|:---|:---| 
|`redpanda_scope_redpanda_connect`| `true` |

If you do not include this tag, the role assumption will fail.


### Redpanda Connect Role

As mentioned above, this role is created when your Redpanda cluster is created.   If your cluster had cluster ID `curl3eo533cmsnt23dv0` then your role would be named `redpanda-curl3eo533cmsnt23dv0-redpanda-connect-pipeline`.  It is vital that we don't change the existing policies attached to this role.   Out of the box there is a policy that allows it to read AWS secrets, and a trust policy that involves IRSA, OIDC, federated identities...it complex.  The good news is you don't need to worry about this.   There _may_ also be another policy in this role (but there might not be, depends on how the cloud team ends up implementing this), but if we want to be explicit, we can create a new policy for this role.   It is important to understand that if we change the existing policies those changes will be reverted by the Redpanda reconciliation process.   But _adding a policy_ won't be subject to that.   So we will need to create a policy that allows this role to assume the dbconnect role.   It should look very much just like this, and it should be attached to the RPCN role.

Note:  the terraform in this repo will not generate this policy, nor will it attach it to the RPCN role.  It is left as an exercise to the reader (for now).  The actual resource will be the ARN of the "db connect" role owned by the Aurora account.

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
                "arn:aws:iam::<Aurora PG AWS Acct ID>:role/demo-allow_connect_to_aurora-iam-demo-user"
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

---

# Troubleshooting

## Missing cross-account policy

If you're failing to connect to postgres_cdc, it is likely that the Redpanda Connect pipeline role is missing the policy to allow it to assume your db-connect role.   You'll see many instances of error messages similar to this in the `__redpanda.connect.logs` topic.

```json
{
    "instance_id": "d5nqpls9m4lc73ejlu80",
    "label": "postgres_cdc",
    "level": "ERROR",
    "message": "Failed to connect to postgres_cdc: unable to generate IAM auth token: assuming role based on configured roles: verifying role assumption for 'arn:aws:iam::211125444193:role/demo-allow_connect_to_aurora-iam-demo-user': operation error STS: GetCallerIdentity, get identity: get credentials: failed to refresh cached credentials, operation error STS: AssumeRole, https response error StatusCode: 403, RequestID: de0401b8-1a52-4cdc-8bb7-88f24dd36d6c, api error AccessDenied: User: arn:aws:sts::861276079005:assumed-role/redpanda-curl3eo533cmsnt23dv0-redpanda-connect-pipeline/1768926423691540220 is not authorized to perform: sts:AssumeRole on resource: arn:aws:iam::211125444193:role/demo-allow_connect_to_aurora-iam-demo-user",
    "path": "root.input",
    "pipeline_id": "d5nfcb0objac738nhf90",
    "time": "2026-01-20T16:27:06.316621814Z"
}
```

The fix is to add an inline policy to your Redpanda Connect pipeline IAM role (`repdanda-<your redpanda cluster ID>-redpanda-connect-pipeline`), which lives in your Redpanda AWS account.   Terraform generated an IAM policy artifact called `generated_x-account-rds-iam-policy.json` which you will need to attach as an inline policy to that role.   Once you add this policy the error should clear on its own.   

The template for this policy is given in the above section, under "Redpanda Connect Role".



