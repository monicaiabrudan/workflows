#!/usr/bin/env bash
# setup_aws.sh: creates the AWS resources for the Day 2 practical (Nextflow on AWS Batch).
# Run it as an AWS ADMIN (not on a participant VM), for example in AWS CloudShell in your chosen region:
#   REGION=eu-west-2 BUCKET=my-unique-bactmap-bucket MAX_VCPUS=64 \
#   BUDGET_USD=100 BUDGET_EMAIL=you@example.org bash setup_aws.sh
# It uses the default VPC. NOT TESTED against your account: read it, run it in a test account
# if you can, and check each step's output.
set -euo pipefail

REGION="${REGION:?set REGION, e.g. eu-west-2}"
BUCKET="${BUCKET:?set BUCKET (must be globally unique)}"
MAX_VCPUS="${MAX_VCPUS:?set MAX_VCPUS for Batch (must fit your EC2 vCPU quota)}"
BUDGET_USD="${BUDGET_USD:?set BUDGET_USD, the budget alert amount}"
BUDGET_EMAIL="${BUDGET_EMAIL:?set BUDGET_EMAIL for budget alerts}"
NAME="${NAME:-bactmap-course}"

export AWS_DEFAULT_REGION="$REGION"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Account $ACCOUNT, region $REGION"
WORK=$(mktemp -d)

echo "== 1. S3 bucket =="
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET"
else
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
cat > "$WORK/lifecycle.json" <<EOF
{"Rules":[{"ID":"expire-participant-data","Status":"Enabled",
 "Filter":{"Prefix":"participants/"},
 "Expiration":{"Days":14},
 "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":2}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration file://"$WORK/lifecycle.json"

echo "== 2. IAM: roles and instance profiles =="
cat > "$WORK/trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > "$WORK/s3policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],
  "Resource":"arn:aws:s3:::$BUCKET"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject",
  "s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
  "Resource":"arn:aws:s3:::$BUCKET/*"}]}
EOF
# Permissions Nextflow's awsbatch executor needs on the machine that runs it (the participant VM).
# Check against the current Nextflow AWS Batch documentation.
cat > "$WORK/batchpolicy.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":[
 "batch:DescribeJobQueues","batch:DescribeComputeEnvironments","batch:RegisterJobDefinition",
 "batch:DeregisterJobDefinition","batch:DescribeJobDefinitions","batch:SubmitJob",
 "batch:DescribeJobs","batch:ListJobs","batch:TerminateJob","batch:CancelJob",
 "batch:TagResource","batch:UntagResource","batch:ListTagsForResource",
 "ecs:DescribeTasks","ecs:DescribeContainerInstances",
 "ec2:DescribeInstances","ec2:DescribeInstanceAttribute","ec2:DescribeInstanceStatus",
 "logs:GetLogEvents"],"Resource":"*"}]}
EOF

# (a) role for the Batch compute instances (runs the containers, reads/writes S3)
aws iam create-role --role-name "$NAME-batch-instance" \
  --assume-role-policy-document file://"$WORK/trust.json" >/dev/null
aws iam attach-role-policy --role-name "$NAME-batch-instance" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role
aws iam put-role-policy --role-name "$NAME-batch-instance" \
  --policy-name s3 --policy-document file://"$WORK/s3policy.json"
aws iam create-instance-profile --instance-profile-name "$NAME-batch-instance" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$NAME-batch-instance" \
  --role-name "$NAME-batch-instance"

# (b) role for the participant VMs (submits jobs, reads/writes S3; no access keys needed)
aws iam create-role --role-name "$NAME-vm" \
  --assume-role-policy-document file://"$WORK/trust.json" >/dev/null
aws iam put-role-policy --role-name "$NAME-vm" --policy-name s3 \
  --policy-document file://"$WORK/s3policy.json"
aws iam put-role-policy --role-name "$NAME-vm" --policy-name batch \
  --policy-document file://"$WORK/batchpolicy.json"
aws iam create-instance-profile --instance-profile-name "$NAME-vm" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$NAME-vm" --role-name "$NAME-vm"
echo "Waiting for IAM to propagate..."; sleep 15

echo "== 3. Launch template (bigger disk + AWS CLI on the compute instances) =="
# Nextflow's awsbatch executor needs the AWS CLI on the compute instance.
# Batch requires user data in MIME multipart format.
cat > "$WORK/userdata.txt" <<'EOF'
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BATCH=="

--==BATCH==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
# Self-contained conda install of the AWS CLI. Nextflow mounts this folder into every job container,
# so it must not depend on system libraries (the standalone AWS CLI v2 needs libz, which minimal
# BioContainers images lack).
curl -sL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -o /tmp/miniforge.sh
bash /tmp/miniforge.sh -b -f -p /opt/miniconda
/opt/miniconda/bin/conda install -y -c conda-forge awscli
--==BATCH==--
EOF
UD=$(base64 < "$WORK/userdata.txt" | tr -d '\n')
cat > "$WORK/lt.json" <<EOF
{"UserData":"$UD",
 "BlockDeviceMappings":[{"DeviceName":"/dev/xvda",
  "Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]}
EOF
LT_ID=$(aws ec2 create-launch-template --launch-template-name "$NAME-lt" \
  --launch-template-data file://"$WORK/lt.json" \
  --query LaunchTemplate.LaunchTemplateId --output text)

echo "== 4. Batch compute environment and job queue (default VPC) =="
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC" != "None" ] || { echo "No default VPC in $REGION: edit this script to use your own subnets."; exit 1; }
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output json)
SG=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text)
cat > "$WORK/ce.json" <<EOF
{"type":"EC2","allocationStrategy":"BEST_FIT_PROGRESSIVE",
 "minvCpus":0,"maxvCpus":$MAX_VCPUS,"desiredvCpus":0,
 "instanceTypes":["optimal"],
 "subnets":$SUBNETS,"securityGroupIds":["$SG"],
 "instanceRole":"arn:aws:iam::$ACCOUNT:instance-profile/$NAME-batch-instance",
 "launchTemplate":{"launchTemplateId":"$LT_ID","version":"\$Latest"},
 "tags":{"Course":"bactmap"}}
EOF
aws batch create-compute-environment --compute-environment-name "$NAME-ce" \
  --type MANAGED --state ENABLED --compute-resources file://"$WORK/ce.json" >/dev/null
echo -n "Waiting for compute environment"
until [ "$(aws batch describe-compute-environments --compute-environments "$NAME-ce" \
    --query 'computeEnvironments[0].status' --output text)" = "VALID" ]; do echo -n "."; sleep 5; done
echo " VALID"
aws batch create-job-queue --job-queue-name "$NAME-queue" --state ENABLED --priority 1 \
  --compute-environment-order order=1,computeEnvironment="$NAME-ce" >/dev/null

echo "== 5. Budget alert =="
aws budgets create-budget --account-id "$ACCOUNT" \
  --budget "{\"BudgetName\":\"$NAME\",\"BudgetLimit\":{\"Amount\":\"$BUDGET_USD\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
  --notifications-with-subscribers "[{\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$BUDGET_EMAIL\"}]}]" \
  || echo "Budget creation failed (check permissions); create it in the console instead."

echo "== 6. vCPU quota check =="
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text \
  | xargs -I{} echo "Running On-Demand Standard vCPU quota: {} (must cover MAX_VCPUS=$MAX_VCPUS plus the participant VMs)" \
  || echo "Could not read the quota; check it in the Service Quotas console."

cat <<EOF

======================== DONE ========================
Region:        $REGION
Bucket:        $BUCKET   (upload data to s3://$BUCKET/course_data/)
Job queue:     $NAME-queue
VM profile:    $NAME-vm   (attach to every participant VM)

Fill these into the Day 2 handbook (aws.config):
  process { executor = 'awsbatch'; queue = '$NAME-queue' }
  workDir = 's3://$BUCKET/participants/<id>/work'
  aws { region = '$REGION'; batch { cliPath = '/opt/miniconda/bin/aws' } }

Next steps:
  1. aws s3 sync ./course_data s3://$BUCKET/course_data/
  2. Attach the instance profile to a VM:
     aws ec2 associate-iam-instance-profile --instance-id <i-xxxx> --iam-instance-profile Name=$NAME-vm
     (or choose it when launching VMs from your AMI)
  3. Run the smoke test from the trainer notes before anyone else does.
EOF
rm -rf "$WORK"
