# Block Leaked Secrets in Your CI/CD Pipeline with Gitleaks, CodePipeline and CodeBuild

## Introduction

Someone commits an access key by mistake. It happens to careful people too. If nothing checks for it, the key rides along with the next deployment, and it stays in the Git history after anyone notices.

In this guide you build a pipeline that checks every commit for secrets before it deploys anything. The scan runs in CodeBuild with Gitleaks. If it finds a secret, the Scan stage fails and the Deploy stage never starts.

You will build it twice. First by hand in the console, so you see every piece. Then with CloudFormation. You will run the same six tests on both:

1. A clean commit passes and deploys.
2. A commit with a fake key is blocked.
3. Deleting the key in the next commit does not unblock the pipeline.
4. The correct way to recover from a finding that is handled.
5. A false positive is allowed with a comment.
6. A custom rule for your own token format.

The demo app is one HTML page in an S3 bucket. The page says which release it is. That makes the proof simple: after a blocked run, the page still shows the old release.

One honest limit. By the time the pipeline sees a secret, it is already pushed to GitHub. The pipeline stops the deployment. It cannot take the key back. If a real key leaks, rotate it first. The section on test 3 explains why.

## Architecture

```
GitHub repo (private)
   |  push
   v
CodePipeline
   Source  -> full clone of the repo, with all Git history
   Scan    -> CodeBuild runs Gitleaks on that history
                 clean  -> passes the site files to the next stage
                 secret -> fails here
   Deploy  -> copies the site files to the S3 site bucket

CodeBuild also saves a redacted JSON report to the artifact bucket.
```

Services used: CodePipeline, CodeBuild, CodeConnections (the link to GitHub), S3, IAM and CloudWatch Logs. Everything runs in `us-east-1`.

## How the pieces fit

**Why a full clone.** A normal CodePipeline source is a zip of one commit. It has no Git history, so a scanner would only see the files as they are now. The Source action has an output format called full clone. With it, CodeBuild gets a real Git repository. Only CodeBuild actions can use this format. That is one reason the scan runs in CodeBuild.

**Why the Deploy stage gets its files from the Scan stage.** The Deploy action cannot read a full clone. So the Scan stage passes on the site files itself, and only when the build succeeds. The files that reach S3 are files that passed the scan.

**Why scan the history and not just the files.** A secret that was committed and then deleted is still in the history. Anyone who clones the repo can read it. The scan looks at every commit reachable from the commit being deployed (`--log-opts="HEAD"`). Without that option, Gitleaks also scans other branches, and a leak on a side branch would block your main branch.

**Why the script refuses a shallow clone.** If the clone is shallow, old commits are missing and the scan would pass without checking them. The script stops with an error instead.

**Why `--redact`.** The secret is hidden in the build log and in the saved report. Otherwise the scanner would copy your secret into more places.

**Why the Gitleaks version and checksum are pinned.** The script downloads one fixed version and checks its SHA-256 before running it. A scanner that runs in your pipeline is code you trust, so it should not change without you knowing.

**Why the report is saved by the script.** The script uploads the report to the artifact bucket before it exits, so you get it on failed runs too, which is when you need it.

**Why two stacks.** A GitHub connection created by CloudFormation starts in `PENDING` status. You must authorize it in the console. The pipeline needs an authorized connection, so the connection lives in stack 1, you authorize it, and then you deploy stack 2.

**What the scanner catches.** Gitleaks uses rules. The default AWS rule looks for a key that starts with `AKIA`, `ASIA`, `ABIA` or `ACCA`, followed by 16 characters from `A-Z` and `2-7`. It skips strings that end in `EXAMPLE`, such as the key in AWS documentation. It also skips strings with very low variety. Rules find patterns. They do not find every secret, so treat this as one layer and not the only one.

## Before you start

You need an AWS account, the AWS CLI v2, `git`, and a GitHub account. The tests use `us-east-1`. Commands are written to work in zsh and bash. The helper scripts must be run with `bash`.

Cost. CodeBuild's free tier covers 100 build minutes per month on `general1.small`, and the rate after that is $0.005 per minute. CodePipeline V2 pipelines cost $0.002 per action execution minute, with 100 free minutes per month. The build has a 10 minute timeout, so one scan costs at most $0.05 even if it hangs. Check the pricing pages before you start, because prices change.

Names used in this guide. They are fixed so that every command and teardown step is exact.

| Resource | Name |
|---|---|
| Throwaway GitHub repo (yours, private) | `gitleaks-demo-app` |
| GitHub connection | `gitleaks-demo-github` |
| Site bucket (versioning on) | `gitleaks-demo-site-<ACCOUNT_ID>-us-east-1` |
| Artifact bucket | `gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1` |
| CodeBuild project | `gitleaks-demo-scan` |
| Pipeline | `gitleaks-demo-pipeline` |
| Log group | `/aws/codebuild/gitleaks-demo-scan` |
| Roles (CloudFormation path) | `gitleaks-demo-codebuild-role`, `gitleaks-demo-pipeline-role` |
| Stacks | `gitleaks-demo-base`, `gitleaks-demo-pipeline-stack` |

Set these in your terminal once:

```bash
export AWS_REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SITE=gitleaks-demo-site-$ACCOUNT_ID-us-east-1
ARTIFACTS=gitleaks-demo-artifacts-$ACCOUNT_ID-us-east-1
```

**Use a separate, throwaway GitHub repo.** The tests put a fake key into the Git history, and history cannot be cleaned without rewriting it. Do not put the fake key in the repo that holds this guide. The watched repo is `gitleaks-demo-app`. It holds the contents of the `demo-app/` folder from this guide's repo. You delete it at the end.

**The fake key.** Run `bash tools/new-fake-key.sh` to print a random string that has the shape of an AWS access key ID. It is not issued by AWS and does not work. The shape matters. A string with a character outside `A-Z2-7` is not matched, and a string ending in `EXAMPLE` is skipped.

Create the repo now: on GitHub, make a new empty private repository named `gitleaks-demo-app`. Then:

```bash
git clone https://github.com/<YOUR_USER>/gitleaks-demo-app.git
cd gitleaks-demo-app
cp -R ../aws-gitleaks-secret-gate/demo-app/. .
git add -A
git commit -m "Initial commit"
git branch -M main
git push -u origin main
```

## Where to watch what happens

- **CodePipeline console.** Open `gitleaks-demo-pipeline`. You see the three stages and which one failed.
- **CodeBuild logs.** The scan prints to the log group `/aws/codebuild/gitleaks-demo-scan`. From a terminal:

  ```bash
  aws logs tail /aws/codebuild/gitleaks-demo-scan --follow
  ```

- **Pipeline state from the CLI.**

  ```bash
  aws codepipeline get-pipeline-state --name gitleaks-demo-pipeline \
    --query 'stageStates[].[stageName,latestExecution.status]' --output text
  ```

- **What is on the site.** The page shows the release number. The bucket is versioned, so you can count versions too:

  ```bash
  aws s3 cp s3://$SITE/index.html - | grep Release
  aws s3api list-object-versions --bucket $SITE --query 'Versions[].[Key,VersionId,LastModified]' --output text
  ```

- **The saved reports.**

  ```bash
  aws s3 ls s3://$ARTIFACTS/reports/ --recursive
  ```

## Manual approach in the console

### Part 1: Create the two buckets

1. Open the S3 console and choose **Create bucket**.
2. Name it `gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1`. Leave **Block all public access** on. Choose **Create bucket**.
3. Choose **Create bucket** again. Name it `gitleaks-demo-site-<ACCOUNT_ID>-us-east-1`. Leave **Block all public access** on.
4. Under **Bucket Versioning**, choose **Enable**. Choose **Create bucket**.

<!-- UNVERIFIED: S3 console button and section names in Part 1 -->

### Part 2: Create the pipeline

1. Open the CodePipeline console and choose **Create pipeline**.
2. Pipeline name: `gitleaks-demo-pipeline`. Service role: **New service role**.
3. Open the advanced settings. For **Artifact store**, choose **Custom location** and pick `gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1`. This keeps every artifact in a bucket with a fixed name, so teardown is exact.

   <!-- UNVERIFIED: "Custom location" wording -->

4. **Source stage.** Source provider: **GitHub (via GitHub App)**. Under **Connection**, create a new connection. Name it `gitleaks-demo-github`, then follow the steps to install the AWS Connector for GitHub app on your account and give it access to `gitleaks-demo-app` only.
5. Back in the wizard, choose the connection, then the repository `gitleaks-demo-app` and the branch `main`. Keep **Start the pipeline on source code change** selected.
6. Under **Output artifact format**, choose **Full clone**.
7. **Build stage.** Build provider: **Other build providers**, then **AWS CodeBuild**. Choose **Create project**. A new window opens.

   <!-- UNVERIFIED: build provider wording -->

8. In the CodeBuild window: project name `gitleaks-demo-scan`. Environment: managed image, Ubuntu, runtime Standard, image `aws/codebuild/standard:7.0`. Service role: new service role. Buildspec: **Use a buildspec file** and leave the name as `buildspec.yml`.
9. Add one environment variable: name `ARTIFACT_BUCKET`, value `gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1`. Choose **Continue to CodePipeline**.

   <!-- UNVERIFIED: CodeBuild project window labels in steps 8 and 9 -->

10. **Deploy stage.** Deploy provider: **Amazon S3**. Bucket: `gitleaks-demo-site-<ACCOUNT_ID>-us-east-1`. Select the option to extract the file before deploy, so the page lands at the bucket root.

    <!-- UNVERIFIED: the Extract option label -->

11. Review and choose **Create pipeline**.

### Part 3: Give the CodeBuild role two permissions

The first run fails. The CodeBuild role the wizard made cannot use the GitHub connection, which a full clone needs. Add the permission, and while you are there, allow the script to save its report.

1. Open the CodeBuild project `gitleaks-demo-scan`. On the **Build details** tab, find the service role and open it in IAM.
2. Add an inline policy with this JSON. Replace `<ACCOUNT_ID>` and `<CONNECTION_ARN>`. You find the connection ARN in Developer Tools, under Settings, Connections.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["codeconnections:UseConnection", "codestar-connections:UseConnection"],
      "Resource": "<CONNECTION_ARN>"
    },
    {
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1/reports/*"
    }
  ]
}
```

3. Name it `gitleaks-demo-extra-access` and save.
4. In CodePipeline, open the pipeline and choose **Release change**. The Scan stage should now start.

<!-- UNVERIFIED: IAM console steps and the "Release change" button -->

### Part 4: Run the tests

Work inside your `gitleaks-demo-app` folder. Set `GUIDE=../aws-gitleaks-secret-gate`.

**Test 1. A clean commit passes.** After Part 3 the pipeline runs on the initial commit. All three stages succeed. Check the page:

```bash
aws s3 cp s3://$SITE/index.html - | grep Release
```

It prints `Release: 1`. In the Scan log you see how many commits were scanned and the line `No secrets found. The scan passed.`

**Test 2. A leaked key is blocked.**

```bash
KEY=$(bash $GUIDE/tools/new-fake-key.sh)
echo "const awsKey = \"$KEY\";" > site/config.js
sed -i.bak 's/Release: 1/Release: 2/' site/index.html && rm site/index.html.bak
git add -A
git commit -m "Release 2"
git push
```

The Scan stage fails and the Deploy stage does not start. The log ends with `SECRETS FOUND`, the rule name, the file, the line, the commit and a fingerprint. It does not show the key. Check the site:

```bash
aws s3 cp s3://$SITE/index.html - | grep Release
```

It still prints `Release: 1`. The bucket has one version of `index.html`. Open the report in the artifact bucket and look at the `Secret` field. It says `REDACTED`.

**Test 3. Deleting the file does not unblock the pipeline.**

```bash
git rm site/config.js
git commit -m "Remove the key file"
git push
```

The Scan fails again. The file is gone from the latest commit, but the key is still in the commit before it, and the scan reads all commits. This is the same view an attacker has. In a real incident, do these in order: rotate the key in AWS, then remove it from the history, then deploy.

**Test 4. Recover after the key is handled.** In a real case you would rewrite the history. A quick, honest alternative is to tell Gitleaks to ignore that one finding, once you have rotated the key. Gitleaks reads a file called `.gitleaksignore` with one fingerprint per line. The fingerprint is in the Scan log and in the report. Use the one from your log:

```bash
echo "<FINGERPRINT_FROM_THE_LOG>" >> .gitleaksignore
git add -A
git commit -m "Ignore the revoked key"
git push
```

The Scan passes and `Release: 2` is deployed. The bucket now has two versions of `index.html`. Review every line you add to `.gitleaksignore` like code, because it switches the check off for that finding.

**Test 5. A false positive with a comment.** Some strings look like keys but are test data. A line that ends with the comment `gitleaks:allow` is skipped.

```bash
echo "const fixture = \"$(bash $GUIDE/tools/new-fake-key.sh)\"; // gitleaks:allow" > site/fixture.js
git add -A
git commit -m "Add a test fixture"
git push
```

The Scan passes. Without the comment it would fail.

**Test 6. A custom rule.** The file `.gitleaks.toml` keeps all default rules and adds one for a token that starts with `demo_tok_` followed by 24 letters or digits.

```bash
echo 'const token = "demo_tok_aB3dE5gH7jK9mN1pQ3sT5vW7";' > site/token.js
git add -A
git commit -m "Add a token"
git push
```

The Scan fails with the rule `demo-internal-token`. You can leave the repo in this state. You delete it in teardown.

## Teardown for the manual approach

Run the steps in this order. Chain the commands with `&&`, so a failure stops the chain.

1. CodePipeline console: delete `gitleaks-demo-pipeline`.
2. CodeBuild console: delete the project `gitleaks-demo-scan`.
3. Empty and delete both buckets. The buckets are versioned, so a normal empty is not enough. The helper script removes every version:

   ```bash
   bash tools/empty-bucket.sh $SITE && aws s3 rb s3://$SITE && \
   bash tools/empty-bucket.sh $ARTIFACTS && aws s3 rb s3://$ARTIFACTS
   ```

4. Developer Tools console, Settings, Connections: delete `gitleaks-demo-github`.
5. Remove what the console left behind: the log group and the IAM roles the wizard created. The script deletes the log group and lists the roles and policies that have `gitleaks-demo` in the name:

   ```bash
   bash tools/cleanup-leftovers.sh
   ```

   Delete the listed roles and policies in the IAM console. Check each name first.

6. On GitHub: delete the repo `gitleaks-demo-app`. In your account settings, under installed GitHub Apps, remove the AWS Connector for GitHub app if you do not use it elsewhere.

<!-- UNVERIFIED: GitHub settings path -->

## Automated approach with CloudFormation

Finish the manual teardown first. Both paths use the same names, and a leftover will make the stack fail.

Use a new empty GitHub repo for this path, named `gitleaks-demo-app` again. Do not reuse the repo from the manual path. Its history holds the fake keys, so the first scan would fail.

**Step 1. Deploy stack 1.** It creates the two buckets and the GitHub connection.

```bash
aws cloudformation deploy \
  --template-file cloudformation/01-base-stack.yaml \
  --stack-name gitleaks-demo-base \
  --region us-east-1
```

**Step 2. Authorize the connection.** CloudFormation creates it as `PENDING`. In the Developer Tools console, open Settings, then Connections. Select `gitleaks-demo-github` and choose the option to update the pending connection. Install the AWS Connector for GitHub app and give it access to `gitleaks-demo-app` only. The status must change to `AVAILABLE`.

<!-- UNVERIFIED: exact button name for completing a pending connection -->

**Step 3. Push the demo app** to the new repo with the commands from "Before you start".

**Step 4. Deploy stack 2.** It creates the log group, the CodeBuild project, both roles and the pipeline. It needs IAM capability because it names the roles.

```bash
aws cloudformation deploy \
  --template-file cloudformation/02-pipeline-stack.yaml \
  --stack-name gitleaks-demo-pipeline-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubRepository=<YOUR_USER>/gitleaks-demo-app BranchName=main \
  --region us-east-1
```

**Step 5. Run the tests.** The pipeline starts by itself. Go to "Part 4: Run the tests" in the manual approach and run Tests 1 to 6. The results are the same. In the CloudFormation path the CodeBuild role already has the connection and report permissions, so there is no failed first run.

## Teardown for the automated approach

1. Delete the pipeline stack, and wait until it finishes:

   ```bash
   aws cloudformation delete-stack --stack-name gitleaks-demo-pipeline-stack && \
   aws cloudformation wait stack-delete-complete --stack-name gitleaks-demo-pipeline-stack
   ```

   This stack owns the log group, the CodeBuild project, both roles and the pipeline.

2. Empty both buckets. CloudFormation cannot delete a bucket that has objects in it.

   ```bash
   bash tools/empty-bucket.sh $SITE && bash tools/empty-bucket.sh $ARTIFACTS
   ```

3. Delete the base stack. It removes both buckets and the connection:

   ```bash
   aws cloudformation delete-stack --stack-name gitleaks-demo-base && \
   aws cloudformation wait stack-delete-complete --stack-name gitleaks-demo-base
   ```

4. On GitHub: delete the repo `gitleaks-demo-app`. Remove the AWS Connector for GitHub app from your account settings if you do not use it elsewhere. Deleting the connection in AWS does not remove the app on the GitHub side.

## Troubleshooting

**The scan passes, but I expected it to block my fake key.**
The key does not match the rule. Two causes show up in practice. One: the key has a character outside `A-Z` and `2-7`, for example a `9`. The rule ignores it. Two: the key ends in `EXAMPLE`, like the key in AWS documentation. The default rule allows it on purpose. Use `bash tools/new-fake-key.sh`, which makes a key with the right shape.

**I deleted the file with the key, and the pipeline still fails.**
This is correct. The scan reads the history, and the key is still in an earlier commit. Rotate the key, then rewrite the history or add the finding to `.gitleaksignore` as in Test 4.

**`ERROR: the clone is shallow, so the scan would miss old commits.`**
The scan script found a shallow clone and stopped on purpose, so it does not pass without checking old commits. Check that the Source action uses the full clone output format.

**`zsh: permission denied: ./tools/new-fake-key.sh`**
A zip file drops the execute bit. Run the helper scripts with `bash tools/new-fake-key.sh`.

## Conclusion

You built a pipeline that checks the full Git history for secrets before it deploys, and you proved it three ways: the page did not change after a blocked run, the log did not show the secret, and a deleted file did not clear the finding. You also saw the two ways to handle a finding on purpose: a one-line comment for test data, and a fingerprint in `.gitleaksignore` after the key is rotated.

Keep the limit in mind. The pipeline blocks the deployment, not the push. To catch a secret earlier, run Gitleaks on the developer's machine before each commit as well.

The code, templates and helper scripts are in the GitHub repo for this guide: https://github.com/Gbengard/aws-gitleaks-secret-gate
