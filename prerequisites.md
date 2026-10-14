---
title: "Requirements"
date: "2026-10-14"
---

# Prerequisites for course participants

Login credentials for their Day 1 VM (SSH key or web console access)

GitHub credentials configured and authenticated via the GitHub CLI (gh auth login)

AWS Course Parameters (Supplied by the Trainer):

Participants do not receive AWS passwords or access keys . Instead, they need a card with:

-   AWS Region (e.g. eu-west-1 or us-east-1) .

-   S3 Bucket Name (<course-bucket>) .

-   Personal S3 Prefix (<your-prefix>, e.g. user01) .

-   AWS Batch Job Queue Name (<queue-name>) .

# Platform setup

Amazon S3 Configuration:

-   Create the course bucket and upload the reference genome (reference.fasta) and approximately 24 paired-end bacterial FASTQ files (\*\_R1*.fastq.gz /* \_R2\*.fastq.gz) under the course_data/ prefix . A 24-sample dataset ensures job parallelism is visible without incurring excessive runtime or storage costs .

-   AWS Batch Compute Environment & Queues: Configure an AWS Batch compute environment (Spot or On-Demand instances) and an ENABLED job queue . Verify the regional vCPU service quotas in AWS Service Quotas to ensure the cluster can scale to accommodate all students launching jobs concurrently . Ensure container images have access to the AWS CLI if required by the Nextflow executor

-   Batch Job Roles: Attach an IAM role to Batch tasks granting read access to course_data/ and write access to student prefixes on S3 .

-    Cost Controls & Teardown: Establish an AWS Billing Budget with automated alert thresholds (e.g. 50%, 80%, 100%) to catch accidental runaways . Prepare an AWS pricing reference table or link to the AWS Pricing Calculator for the Section 3.8 cost estimation exercise .

-   Plan an end-of-course cleanup routine to purge transient student work/ prefixes (aws s3 rm s3://<course-bucket>/<prefix>/work --recursive) to prevent lingering storage bills .
