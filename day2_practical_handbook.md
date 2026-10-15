# Day 2 Practical Handbook: Cloud and AI-Assisted Bacterial Genomics

**Friday 30 October 2026 · Afternoon practical**

Yesterday you ran nf-core/bactmap on a single computer. Today you will scale the same workflow to the cloud with AWS, measure what changed, estimate what it costs, and learn to use AI coding assistants without trusting them blindly.

> **Trainer pre-flight (complete before the day).** Everything marked *(trainer)* below must be set up in advance and tested end to end. Resource names and the AWS Batch details depend on how your account is built, so the placeholders in `<angle brackets>` are for you to fill in.
> 
> - An S3 bucket with a prefix per participant for work and results, plus a `course_data/` prefix holding the FASTQ files and `reference.fasta` (a dataset of about 24 samples works well, so that parallelism is visible).
> - An AWS Batch compute environment and job queue sized for the whole class (check the vCPU service quota in the region), with the AWS CLI available to jobs if Nextflow needs it.
> - An instance profile on the participant VMs allowing S3 access and Batch job submission, so **nobody needs access keys**.
> - A Batch job role with S3 access, a billing budget with alerts, and a teardown plan.
> - The same Nextflow pin as Day 1: `NXF_VER=24.10.5` and `-r 1.0.0`.

---

## Prerequisites

- Day 1 completed: you can run bactmap and you have a working `samplesheet.csv`, `params.json` and Git setup.
- Your Day 1 VM login, and your GitHub login (`gh auth login`, see Day 1).
- The AWS details from the trainers: region, bucket name, your personal prefix and the Batch queue name. You will **not** be given an AWS password or keys.

---

## Part A: Cloud concepts in one page

| Concept | Meaning | Why it matters for genomics |
| --- | --- | --- |
| **S3** | Object storage organised in buckets | Cheap, durable storage for reads and results, shareable across teams |
| **EC2** | Virtual machines you rent by time | What Batch starts for you when jobs are queued |
| **AWS Batch** | Job scheduler that creates machines on demand | Lets 100 samples run in parallel without owning 100 cores |
| **IAM** | Permissions for people and machines | Controls who can read data or spend money |
| **Region** | Physical location of the data centres | Affects cost, latency and **where data legally resides** |
| **Spot vs on-demand** | Spare capacity at a discount vs guaranteed capacity | Cheaper but can be interrupted; Nextflow can retry |

Key idea: on a laptop or one VM you pay for the machine whether it is busy or not. In the cloud you pay for what you use, and it scales out, but costs can grow quickly if you forget to turn things off.

---

## Practical 3: Scaling a bacterial genomics workflow

### 3.1 Check your cloud access (10 min)

```bash
aws sts get-caller-identity            # who the VM is acting as
aws s3 ls s3://<course-bucket>/course_data/
aws batch describe-job-queues --job-queues <queue-name> --query 'jobQueues[0].state'
```

You should see your identity, the course files and `ENABLED`. If any of these fail, tell a trainer. **Never** paste access keys into a file or into an AI tool.

### 3.2 Build an S3 samplesheet (10 min)

Cloud runs read from S3, so the samplesheet points to `s3://` paths instead of local ones.

```bash
mkdir -p ~/bactmap-day2 && cd ~/bactmap-day2 && git init
BUCKET=s3://<course-bucket>
echo "sample,fastq_1,fastq_2" > samplesheet_full.csv
aws s3 ls $BUCKET/course_data/ | awk '{print $4}' | grep '_R1.*fastq.gz' | while read f; do
  echo "${f%%_R1*},$BUCKET/course_data/$f,$BUCKET/course_data/${f/_R1/_R2}"
done >> samplesheet_full.csv
head -5 samplesheet_full.csv
head -5 samplesheet_full.csv > samplesheet_small.csv     # header + 4 samples
wc -l samplesheet_*.csv
```

You now have a **small** set (4 samples) for a fair local-versus-cloud comparison and a **full** set to see scaling.

### 3.3 Configuration (10 min)

Create `monitor.config` so every run records comparable metrics:

```groovy
trace.fields       = 'task_id,name,status,cpus,memory,realtime,peak_rss'
trace.raw          = true     // realtime in milliseconds, bytes for memory
trace.overwrite    = true
report.overwrite   = true
timeline.overwrite = true
```

Create `aws.config` *(trainer provides the values)*:

```groovy
process {
    executor = 'awsbatch'
    queue    = '<queue-name>'
}

workDir = 's3://<course-bucket>/<your-prefix>/work'

aws {
    region = '<region>'
    // batch.cliPath = '<path>'   // only if the trainers tell you to set it
}
```

Check that the configuration parses:

```bash
nextflow -c aws.config -c monitor.config config | head -30
```

Never put keys, tokens or your real prefix in a public repository; use the placeholder form when you publish.

### 3.4 Baseline: run locally (25 min)

Run the 4-sample set on your VM, using Docker as yesterday. Save this as `run_local.sh`:

```bash
export NXF_VER=24.10.5
nextflow run nf-core/bactmap -r 1.0.0 -profile docker \
  -c monitor.config \
  --input samplesheet_small.csv \
  --reference s3://<course-bucket>/course_data/reference.fasta \
  --outdir results/local_small \
  -with-report results/local_small_report.html \
  -with-trace results/local_small_trace.txt \
  -with-timeline results/local_small_timeline.html
```

Write down the **Duration** printed at the end. While waiting, start 3.5 in a second terminal.

### 3.5 Run on AWS Batch (30 min)

Save as `run_cloud_small.sh`, then run it:

```bash
export NXF_VER=24.10.5
nextflow run nf-core/bactmap -r 1.0.0 \
  -c aws.config -c monitor.config \
  --input samplesheet_small.csv \
  --reference s3://<course-bucket>/course_data/reference.fasta \
  --outdir s3://<course-bucket>/<your-prefix>/results/cloud_small \
  -with-report results/cloud_small_report.html \
  -with-trace results/cloud_small_trace.txt \
  -with-timeline results/cloud_small_timeline.html
```

There is no `-profile docker`: on Batch each task runs in its container automatically. Then run the full set with `--input samplesheet_full.csv`, `--outdir .../results/cloud_full`, and `cloud_full_*` file names. Save as `run_cloud_full.sh`.

#### If a run stops or fails: use `-resume`

Nextflow remembers which tasks finished successfully. If a run is interrupted or fails, fix the problem and run **the same command again with `-resume` added at the end**. Tasks that already completed are marked `cached` and are not repeated, so you do not pay for them twice. Only the failed and unfinished tasks run again.

```bash
cd ~/bactmap-day2                  # the same folder as before
export NXF_VER=24.10.5
nextflow run nf-core/bactmap -r 1.0.0 \
  -c aws.config -c monitor.config \
  --input samplesheet_small.csv \
  --reference s3://<course-bucket>/course_data/reference.fasta \
  --outdir s3://<course-bucket>/<your-prefix>/results/cloud_small \
  -with-report results/cloud_small_report.html \
  -with-trace results/cloud_small_trace.txt \
  -with-timeline results/cloud_small_timeline.html \
  -resume
```

Rules for `-resume`:

- Run it from the **same folder** (Nextflow keeps its history in a hidden `.nextflow` folder there).
- Keep the **same inputs, parameters and `workDir`**. If you change a parameter, the affected tasks run again, which is what you want.
- Do **not** delete the `work/` folder in S3 before resuming. Clean up only when you have finished (step 3.9).
- Use `nextflow log` to see previous runs, and `-resume <run-name>` to resume a specific one.

### 3.6 Monitor execution (during runs)

- **Console:** note which processes are waiting and which run.
- **`nextflow log`:** `nextflow log last -f name,status,duration`.
- **Batch console** (ask the trainers for the link): watch jobs move from `SUBMITTED` to `RUNNABLE` (waiting for a machine), `STARTING`, `RUNNING`, then `SUCCEEDED` or `FAILED`.
- **S3 console:** browse your `work/` and `results/` prefixes.
- **Logs:** a failed task has output in CloudWatch Logs, and also in `.command.err` in its work directory.

Discuss: why did the first cloud tasks sit in `RUNNABLE` for a few minutes? (Machines are being started.) What does that mean for very short jobs?

### 3.7 Compare local versus cloud (20 min)

Compute CPU-hours from each trace file:

```bash
for t in results/*_trace.txt; do
  awk -F'\t' -v f="$t" 'NR>1 && $3=="COMPLETED" {h+=$4*$6/3600000; n++}
       END {printf "%s: %d tasks, %.2f CPU-hours\n", f, n, h}' "$t"
done
```

Fill in the table (wall-clock is the **Duration** shown at the end of each run or in the HTML report):

| Measure | Local, 4 samples | Cloud, 4 samples | Cloud, full set |
| --- | --- | --- | --- |
| Samples | 4 | 4 |  |
| Wall-clock time |  |  |  |
| Total CPU-hours |  |  |  |
| Wall-clock per sample |  |  |  |
| Peak parallel tasks (from timeline) |  |  |  |

Questions:

1. For 4 samples, was the cloud faster? Why or why not?
2. How did wall-clock time change from 4 to the full set, locally (estimate) versus on the cloud?
3. Compare the results files. Are the trees and MultiQC reports equivalent? Is that what you expect, and why does it matter?

### 3.8 Estimate costs (20 min)

**You estimate; the AWS bill arrives later.** Billing data can take up to a day to appear, so work from your measurements.

| Cost item | How to estimate |
| --- | --- |
| Compute | Instance-hours × hourly price. Use CPU-hours ÷ (vCPUs per instance × utilisation, say 50 to 80%) for instance-hours |
| Storage (S3) | GB stored × price per GB-month × months kept |
| Data transfer | Free in, charged out of AWS or across regions |
| Requests, logs, extras | Usually small, but note them |

1. Look up current prices for your region on the AWS pricing pages or in the AWS Pricing Calculator ([https://calculator.aws](https://calculator.aws)). Your trainers may give you a price table.
2. Size your S3 data: `aws s3 ls --recursive --summarize s3://<course-bucket>/<your-prefix>/ | tail -2`.
3. Estimate the compute cost of your full-set run.
4. Divide by the number of samples for a **cost per sample**.
5. Scale up: what would 500 isolates cost, and what would storing them for a year cost?
6. Name two ways to reduce it (for example, spot capacity, deleting the `work/` directory when finished, cheaper storage classes, or right-sizing task resources).

**Illustrative only (invented numbers, not real prices).** If a run used 20 CPU-hours at 60% utilisation on machines costing 0.04 per vCPU-hour, compute is about 20 ÷ 0.6 × 0.04 = 1.33 currency units, or about 0.06 per sample for 24 samples. Use your own measurements and real prices, not these.

### 3.9 Clean up (5 min)

```bash
nextflow clean -f -before $(nextflow log -q | tail -1)    # old local work dirs
aws s3 rm s3://<course-bucket>/<your-prefix>/work --recursive
```

Leaving work directories on S3 keeps costing money. Do **not** delete other people's prefixes.

---

## Part B: AI coding assistants, used responsibly

*(This hands-on is an addition to the single Practical 3 listed in the schedule, so that the AI learning outcomes are practised. Run it between 3.5 and 3.7 while Batch jobs run, or as a separate 30-minute block.)*

### Ground rules

- **You are accountable for any code you run**, whoever or whatever wrote it.
- **Never share:** passwords, access keys, patient or personal identifiers, unpublished or sensitive sequence data or metadata, or anything your organisation restricts. Use the public course data only. Check your organisation's policy on which AI tools are approved.
- **Validate on a known answer** before trusting the output on real samples.
- **Record that you used AI** (see the deliverable).

### Prompts that work better

Include: **context** (tool and version, operating system), **task**, **inputs and outputs**, **constraints** (versions, DSL2, pinned containers), **output format**, and ask for **assumptions and risks**. Example:

> I am running Nextflow 24.10.5 on Ubuntu with nf-core/bactmap 1.0.0. Write a DSL2 process that runs `seqkit stats -a -T` on paired FASTQ files and writes one TSV per sample. Use a pinned BioContainers image, use `task.cpus`, and list any assumptions or options you are unsure exist.

Then iterate: paste the **exact error message** back, and ask for a minimal change rather than a rewrite.

### Exercise: find the errors (20 min)

The following code was written to look plausible. Find **at least six** problems. Do not run it first.

```groovy
#!/usr/bin/env nextflow
params.reads = "/home/alice/data/*_{1,2}.fastq.gz"
params.ref   = "/home/alice/ref/genome.fa"

Channel.fromFilePairs(params.reads).into { reads_ch }

process align {
    container 'biocontainers/bwa:latest'

    input:
    set sample, file(reads) from reads_ch

    output:
    file "${sample}.bam" into bam_ch

    script:
    """
    bwa mem -t 4 --fast ${params.ref} ${reads} | samtools view -b > ${sample}.bam
    """
}
```

Hints to check against (after you have tried): the syntax style, the container tag, whether the options exist, whether the reference is indexed, whether `samtools` is in that container, hard-coded paths and CPU counts, missing sorting and publishing, and anything that would break on a different computer. Then ask an AI assistant to review the same code and compare what it finds with your list. Did it miss anything, or invent a problem?

### Then try it yourself (10 min)

1. Ask an assistant to write something small for today's pipeline, such as a process that summarises read counts per sample.
2. Check it with the **validation checklist** below.
3. Keep your prompt, the output, and what you had to fix, in `docs/ai_log.md`.

### Validation checklist

- [ ] Do the tools, options and parameters actually exist? Check the manual or `--help`.
- [ ] Are versions pinned (container tags, `-r`, Nextflow)? No `latest`.
- [ ] Is it valid for **our** Nextflow version and DSL2?
- [ ] No hard-coded personal paths, keys or sample identifiers.
- [ ] Does it run on a tiny test set with a known expected result?
- [ ] Do the results make biological sense (mapping rates, SNP counts, tree shape)?
- [ ] Can a colleague read, understand and reproduce it?

### Data privacy and governance: discussion (10 min)

For each, decide whether it may be pasted into a public AI tool, may be shared only if approved, or must never be shared:

1. A Nextflow script with your institute's AWS bucket name in it.
2. A samplesheet whose sample names are hospital patient numbers.
3. Metadata with collection dates, postcodes and ages from an outbreak.
4. An error message from a failed run.
5. A public ENA accession and its published read statistics.

Then discuss: who approves AI tools where you work? Where is AI use recorded? What happens when AI-generated code produces a wrong result in a surveillance report?

---

## Deliverable (suggested)

Add to your GitHub repository (new `bactmap-day2`, or a `day2/` folder in your Day 1 repo):

```
├── samplesheet_small.csv   (with s3:// paths; replace the bucket with <course-bucket> if you publish)
├── aws.config              (placeholders only, no keys)
├── monitor.config
├── run_local.sh
├── run_cloud_small.sh
├── run_cloud_full.sh
├── results/*_report.html and *_trace.txt   (reports and traces from each run)
├── docs/comparison.md      (the 3.7 table and your answers)
├── docs/cost_estimate.md   (your calculation, with the prices and date you used)
└── docs/ai_log.md          (prompts, outputs, fixes; AI use statement)
```

Add this to your README:

```markdown
## AI use statement
Tools used: <name and version, or "none">. Used for: <e.g. drafting a process>.
All AI-generated code was reviewed, tested on <data>, and corrected where needed.
No sensitive data or credentials were shared with AI tools.
```

Publish as on Day 1: `gh auth login`, then `gh repo create bactmap-day2 --public --source=. --remote=origin --push`, then `gh auth logout`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Unable to locate credentials` | The VM's instance profile is missing or not attached | Tell a trainer; don't create keys yourself |
| Jobs stay `RUNNABLE` for a long time | Queue capacity or vCPU quota reached, or machines still starting | Wait a few minutes, then tell a trainer |
| `AccessDenied` on S3 | Wrong bucket or prefix, or missing permission | Check the path and your prefix |
| Task fails immediately with a container error | Image can't be pulled or isn't available | Read the CloudWatch log or `.command.err` |
| `Trace file already exists` | Old report files | Use `monitor.config`, which allows overwriting |
| Run is much slower than expected | Short tasks dominated by startup time | Compare CPU-hours with wall-clock |

## Glossary

**Bucket** – top-level S3 container. **Prefix** – the "folder" part of an S3 path. **Job queue** – where Batch holds jobs until a machine is available. **Spot instance** – discounted, interruptible machine. **Hallucination** – plausible but wrong AI output, such as an option that does not exist. **Instance profile** – a role attached to a VM that gives it AWS permissions without keys.