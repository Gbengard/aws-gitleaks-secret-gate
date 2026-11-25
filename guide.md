# Block Leaked Secrets in Your CI/CD Pipeline with Gitleaks, CodePipeline and CodeBuild

## Introduction

Someone commits an access key by mistake. It happens to careful people too. If nothing checks for it, the key rides along with the next deployment.

In this guide you build a pipeline that checks every commit for secrets before it deploys anything. The scan runs in CodeBuild with Gitleaks. If it finds a secret, the Build stage fails and the Deploy stage never starts.

You build it twice. First by hand in the console, so you see every piece. Then with CloudFormation. You run the same six tests on both:

1. A clean commit passes and deploys.
2. A commit with a fake key is blocked.
3. Deleting the key file lets the pipeline pass, and the key is still in the Git history.
4. A false positive is allowed with a comment.
5. A custom rule catches your own token format.
6. A finding you have dealt with is accepted through an ignore file.

The demo app is one HTML page in an S3 bucket. The page says which release it is. That makes the proof simple: after a blocked run, the page still shows the old release.

Two honest limits. First, this scan checks the files in the commit being built. It does not read the Git history. Test 3 shows what that means. Second, by the time the pipeline sees a secret, it is already pushed to GitHub. The pipeline stops the deployment. It cannot take the key back. If a real key leaks, rotate it first.

## Architecture

```
GitHub repo (private)
   |  push
   v
CodePipeline
   Source  -> zip of the files in the commit
   Build   -> CodeBuild runs Gitleaks on those files
                 clean  -> passes the site files to the next stage
                 secret -> fails here
   Deploy  -> copies the site files to the S3 site bucket

CodeBuild also saves a redacted JSON report to the artifact bucket.
```

Services used: CodePipeline, CodeBuild, S3, IAM, CloudWatch Logs and, for the CloudFormation path, Secrets Manager. Everything runs in `us-east-1`.

## How the pieces fit

**The source is a zip of files.** The Source action is GitHub (via OAuth app). It gives the pipeline a zip of the files at the commit being built, with no `.git` folder. That is why the scan looks at files only. The GitHub (via GitHub App) action can give CodeBuild a full clone with the history. If you need the history scanned, use that action with the output format Full clone, and run `gitleaks git` instead of `gitleaks dir`. AWS lists the OAuth action as not recommended, but pipelines that use it keep working.

**Why the Deploy stage gets its files from the Build stage.** The Build stage hands the site files to the Deploy stage. CodeBuild packs those files even when the scan fails. But a failed Build action fails the whole stage, so the Deploy stage never starts. The only files that reach S3 come from a run where the scan passed.

**Why `--redact`.** The secret is hidden in the build log and in the saved report. Otherwise the scanner would copy your secret into more places.

**Why the Gitleaks version and checksum are pinned.** The script downloads one fixed version and checks its SHA-256 before it runs it. A scanner that runs in your pipeline is code you trust, so it should not change without you knowing.

**Why the report is saved by the script.** The script uploads the report to the artifact bucket before it exits, so you get it on failed runs too, which is when you need it.

**Why the script checks for the `site` folder.** If the source files did not arrive, an empty scan would pass. The script stops with an error instead.

**Why the roles need extra access in the console path.** The console wizard builds each role for its own default bucket and its own project. This setup uses buckets with fixed names, so you add the missing access yourself in Part 3. The CloudFormation template already includes it.

**How changes are detected.** In the console, CodePipeline creates a GitHub webhook for you. In the CloudFormation template the action polls GitHub for changes, which is the default for this action and needs no webhook. AWS recommends webhooks for production. Polling keeps this demo to one secret.

**What the scanner catches.** Gitleaks uses rules. The default AWS rule looks for a key that starts with `AKIA`, `ASIA`, `ABIA` or `ACCA`, followed by 16 characters from `A-Z` and `2-7`. It skips strings that end in `EXAMPLE`, such as the key in AWS documentation. It also skips strings with very low variety. Rules find patterns. They do not find every secret, so treat this as one layer and not the only one.

## Before you start

You need an AWS account, a GitHub account, and `git` on your computer. The tests use `us-east-1`. The manual approach uses the AWS console and `git`. The automated approach also needs the AWS CLI v2. The helper scripts in `tools/` run on your computer with `bash`.

Cost. CodeBuild's free tier covers 100 build minutes per month on `general1.small`, and the rate after that is $0.005 per minute. CodePipeline V2 pipelines cost $0.002 per action execution minute, with 100 free minutes per month. The build has a 10 minute timeout, so one scan costs at most $0.05 even if it hangs. The CloudFormation path also stores one secret in Secrets Manager, which has a small monthly charge. Check the pricing pages before you start, because prices change.

Names used in this guide. They are fixed so that every step and teardown is exact.

| Resource | Name |
|---|---|
| Throwaway GitHub repo (yours, private) | `gitleaks-demo-app` |
| Site bucket (versioning on) | `gitleaks-demo-site-<ACCOUNT_ID>-us-east-1` |
| Artifact bucket | `gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1` |
| CodeBuild project | `gitleaks-demo-scan` |
| Pipeline | `gitleaks-demo-pipeline` |
| Log group | `/aws/codebuild/gitleaks-demo-scan` |
| Roles made by the console wizard | `AWSCodePipelineServiceRole-us-east-1-gitleaks-demo-pipeline`, `codebuild-gitleaks-demo-scan-service-role` |
| Roles made by CloudFormation | `gitleaks-demo-codebuild-role`, `gitleaks-demo-pipeline-role` |
| Secret (CloudFormation path) | `gitleaks-demo/github-token` |
| Stack (CloudFormation path) | `gitleaks-demo-stack` |

`<ACCOUNT_ID>` is your 12 digit AWS account ID. You find it in the account menu at the top right of the console.

<!-- UNVERIFIED: where the console shows the account ID -->

**Use a separate, throwaway GitHub repo.** The tests put a fake key into the Git history, and history cannot be cleaned without rewriting it. Do not put the fake key in the repo that holds this guide. The watched repo is `gitleaks-demo-app`. It holds the contents of the `demo-app/` folder from this guide's repo. You delete it at the end.

**The fake key.** Run `bash tools/new-fake-key.sh` on your computer to print a random string that has the shape of an AWS access key ID. It is not issued by AWS and does not work. The shape matters. A string with a character outside `A-Z2-7` is not matched, and a string ending in `EXAMPLE` is skipped.

Create the repo: on GitHub, make a new empty private repository named `gitleaks-demo-app`. Then, in a terminal on your computer:

```bash
git clone https://github.com/<YOUR_USER>/gitleaks-demo-app.git
cd gitleaks-demo-app
cp -R ../aws-gitleaks-secret-gate/demo-app/. .
git add -A
git commit -m "Initial commit"
git branch -M main
git push -u origin main
```

Check that GitHub now has the branch. This must print one line that ends with `refs/heads/main`:

```bash
git ls-remote --heads origin main
```

Keep your folder with this guide's files up to date. A stale copy gives you an old version of the scan script.

## Where to watch what happens

In the console:

- **CodePipeline.** Open `gitleaks-demo-pipeline`. You see the three stages and which one failed.
- **CodeBuild logs.** Open the CodeBuild console, then **Build projects**, then `gitleaks-demo-scan`. Open the latest build under **Build history** and read the **Build logs** tab. The same log is in CloudWatch Logs, in the log group `/aws/codebuild/gitleaks-demo-scan`.
- **The site.** The page is a file in the site bucket. It is not a public website, because the bucket blocks public access. Open the S3 console and choose the site bucket. On the **Objects** tab you should see `index.html`. Select it and choose **Open**. The page opens in a new browser tab and shows the release number. Turn on **Show versions** to count the versions of the file. If **Open** is missing or shows `AccessDenied`, do not use the **Object URL** link. That link is not signed, and the bucket is private, so it is always denied. Choose **Download** instead and open the downloaded `index.html` in a browser or a text editor. The release number is inside the file. If the bucket has no `index.html`, the Deploy stage has not succeeded yet. Check it in the CodePipeline console.
- **The saved reports.** Open the artifact bucket and its `reports/` folder. Each build has a folder with a `gitleaks-report.json` file you can download.

<!-- UNVERIFIED: console tab, toggle and button names in this section -->

The automated approach has the same checks as terminal commands.

## Manual approach in the console

You use the AWS console and `git` only.

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

4. **Source stage.** Source provider: **GitHub (via OAuth app)**. Choose **Connect to GitHub** and approve the access request. Pick the repository `gitleaks-demo-app` and the branch `main`. Keep the option that starts the pipeline on changes, so CodePipeline creates the webhook.

   <!-- UNVERIFIED: wording of the connect button and of the change detection option -->

5. **Build stage.** Build provider: **Other build providers**, then **AWS CodeBuild**. Choose **Create project**. A new window opens.

   <!-- UNVERIFIED: build provider wording -->

6. In the CodeBuild window: project name `gitleaks-demo-scan`. Environment: managed image, Ubuntu, runtime Standard, image `aws/codebuild/standard:7.0`. Service role: new service role. Buildspec: **Use a buildspec file** and leave the name as `buildspec.yml`.
7. Add one environment variable: name `ARTIFACT_BUCKET`, value `gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1`. Choose **Continue to CodePipeline**.

   <!-- UNVERIFIED: CodeBuild project window labels in steps 6 and 7 -->

8. **Deploy stage.** Deploy provider: **Amazon S3**. Bucket: `gitleaks-demo-site-<ACCOUNT_ID>-us-east-1`. Select the option to extract the file before deploy, so the page lands at the bucket root.

   <!-- UNVERIFIED: the Extract option label -->

9. Review and choose **Create pipeline**. The pipeline starts a first run by itself. It fails until you finish Part 3.

**Turn off automatic retry on the Build stage.** The wizard can set a stage to retry when it fails. A leaked secret fails the same way every time, so a retry only runs the scan twice and makes the runs harder to read.

1. Open the pipeline and choose **Edit**.
2. On the Build stage, choose the edit option for the stage.
3. Find the setting for what happens when the stage fails. If it is set to retry, change it so the stage fails.
4. Save the stage and save the pipeline.

<!-- UNVERIFIED: the console wording of the stage failure setting -->

### Part 3: Give the two roles the access they need

The wizard builds each role for its own default bucket and its own project. This setup uses buckets with fixed names, so the first run fails until you add the access below. You add one inline policy to each role. In the IAM console, open the role, choose **Add permissions**, then **Create inline policy**, open the **JSON** tab, paste the policy, and give it the name shown.

**The CodeBuild role.** Its name is `codebuild-gitleaks-demo-scan-service-role`. It must read the source files from the artifact bucket and write the scan output and the report to it. Replace `<ACCOUNT_ID>` in the JSON. Name the policy `gitleaks-demo-extra-access`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"],
      "Resource": "arn:aws:s3:::gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketAcl", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::gitleaks-demo-artifacts-<ACCOUNT_ID>-us-east-1"
    }
  ]
}
```

**The pipeline role.** Its name is `AWSCodePipelineServiceRole-us-east-1-gitleaks-demo-pipeline`. It must start the CodeBuild project and write the page to the site bucket. Replace `<ACCOUNT_ID>` in the JSON. Name the policy `gitleaks-demo-pipeline-extra-access`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["codebuild:StartBuild", "codebuild:BatchGetBuilds"],
      "Resource": "arn:aws:codebuild:us-east-1:<ACCOUNT_ID>:project/gitleaks-demo-scan"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl", "s3:PutObjectVersionAcl"],
      "Resource": "arn:aws:s3:::gitleaks-demo-site-<ACCOUNT_ID>-us-east-1/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketVersioning", "s3:GetBucketAcl", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::gitleaks-demo-site-<ACCOUNT_ID>-us-east-1"
    }
  ]
}
```

Then open the pipeline and choose **Release change**.

<!-- UNVERIFIED: IAM console wording and the Release change button -->

### Part 4: Run the tests

Work inside your `gitleaks-demo-app` folder, not in this guide's folder. Set `GUIDE` to the full path of this guide's folder, for example:

```bash
cd ~/Downloads/gitleaks-demo-app
GUIDE=$HOME/Downloads/aws-gitleaks-secret-gate
pwd
ls site scripts
```

`pwd` must end with `gitleaks-demo-app`, and `ls` must list `index.html` and `secret-scan.sh`. If you run the tests in the guide's own repo, the fake key lands in the wrong repo. Each push starts the pipeline by itself. Wait for the run to finish before the next test.

**Test 1. A clean commit passes.** After Part 3, the run on the initial commit passes. All three stages succeed. Open the page from the site bucket as described in "Where to watch". It shows `Release: 1`. In the Build log you see how many files were scanned and the line `No secrets found. The scan passed.`

**Test 2. A leaked key is blocked.**

```bash
KEY=$(bash $GUIDE/tools/new-fake-key.sh)
echo "const awsKey = \"$KEY\";" > site/config.js
sed -i.bak 's/Release: 1/Release: 2/' site/index.html && rm site/index.html.bak
git add -A
git commit -m "Release 2"
git push
```

In the CodePipeline console, the Build stage fails and the Deploy stage does not start. The Build log ends with `SECRETS FOUND`, the rule name, the file, the line and a fingerprint. It does not show the key. Open the page in the site bucket again. It still shows `Release: 1`, and **Show versions** lists one version of `index.html`. Download the report from the `reports/` folder of the artifact bucket and look at the `Secret` field. It says `REDACTED`.

**Test 3. Deleting the file lets the pipeline pass.**

```bash
git rm site/config.js
git commit -m "Remove the key file"
git push
```

The Build stage passes and the page shows `Release: 2`. The scan only reads the files in this commit, and the file is gone. But the key is still in the Git history on GitHub. Find the commit that added it:

```bash
git log --oneline --diff-filter=A -- site/config.js
git show <COMMIT_FROM_THE_LINE_ABOVE>:site/config.js
```

Anyone who can clone the repo can read the key from that commit. A passing pipeline does not mean the key is safe. In a real incident, rotate the key first, then remove it from the history.

**Test 4. A false positive with a comment.** Some strings look like keys but are test data. A line that ends with the comment `gitleaks:allow` is skipped.

```bash
echo "const fixture = \"$(bash $GUIDE/tools/new-fake-key.sh)\"; // gitleaks:allow" > site/fixture.js
git add -A
git commit -m "Add a test fixture"
git push
```

The Build stage passes. Without the comment it would fail.

**Test 5. A custom rule.** The file `.gitleaks.toml` keeps all default rules and adds one for a token that starts with `demo_tok_` followed by 24 letters or digits.

```bash
echo 'const token = "demo_tok_aB3dE5gH7jK9mN1pQ3sT5vW7";' > site/token.js
git add -A
git commit -m "Add a token"
git push
```

The Build stage fails with the rule `demo-internal-token`.

**Test 6. Accept a finding you have dealt with.** Gitleaks reads a file called `.gitleaksignore` with one fingerprint per line. You take the fingerprint from the log of the build that failed in Test 5.

1. Open the CodeBuild console and choose **Build projects**, then `gitleaks-demo-scan`.
2. Under **Build history**, open the latest build. It is the one that failed after your `demo_tok_` push. Check that its status is **Failed**. A build that passed has no finding in its log.
3. Open the **Build logs** tab and scroll to the bottom. If the tab shows only the end of the log, use the link to view the entire log in CloudWatch.
4. After the line `SECRETS FOUND` you see a block like this. For the token file in Test 5 it reads:

   ```
     rule=demo-internal-token file=site/token.js line=1
     fingerprint=site/token.js:demo-internal-token:1
   ```

5. Copy everything after `fingerprint=`. The fingerprint is the file name, the rule and the line number, separated by colons. It does not include the secret.

<!-- UNVERIFIED: the CodeBuild console tab and link names in steps 1 to 3 -->

Use the value from your own log, because it differs if your file or line is different. If the log shows more than one finding, copy every `fingerprint=` line into `.gitleaksignore`, one per line. If you cannot find the lines in the log, the same value is in the `Fingerprint` field of `gitleaks-report.json`. Download that file from the `reports/` folder of the artifact bucket, in the folder for that build number.

Then add it to the file in your `gitleaks-demo-app` folder and push:

```bash
echo "site/token.js:demo-internal-token:1" >> .gitleaksignore
git add -A
git commit -m "Ignore the demo token"
git push
```

The Build stage passes. Because the fingerprint names a place and not a secret, it also silences a different secret that later lands on the same line of the same file. Review every line you add to `.gitleaksignore` like code.

## Teardown for the manual approach

Run the steps in this order, in the console.

1. CodePipeline console: delete `gitleaks-demo-pipeline`.
2. CodeBuild console: delete the project `gitleaks-demo-scan`.
3. S3 console: for each of the two buckets, empty it, then delete it. The buckets are versioned, so the empty action must remove every version.

   <!-- UNVERIFIED: that the console Empty action removes all object versions -->

4. CloudWatch console, log groups: delete `/aws/codebuild/gitleaks-demo-scan`.
5. IAM console, roles: delete `AWSCodePipelineServiceRole-us-east-1-gitleaks-demo-pipeline` and `codebuild-gitleaks-demo-scan-service-role`. Search for `gitleaks-demo` to find any other role the wizard made. Then open **Policies**, filter for customer managed policies, search for `gitleaks-demo`, and delete what is left over.
6. GitHub: delete the repo `gitleaks-demo-app`. In your account settings, remove the authorization you gave to AWS CodePipeline if you do not use it elsewhere.

   <!-- UNVERIFIED: GitHub settings path -->

The names are fixed, so a leftover will make the CloudFormation path fail. That path starts with a check for leftovers.

## Automated approach with CloudFormation

This approach uses the AWS CLI v2 and the same `git` commands. Finish the manual teardown first. Both paths use the same names.

Set these in your terminal once:

```bash
export AWS_REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SITE=gitleaks-demo-site-$ACCOUNT_ID-us-east-1
ARTIFACTS=gitleaks-demo-artifacts-$ACCOUNT_ID-us-east-1
```

**Step 1. Check for leftovers.** The script deletes the log group and any CodePipeline webhook for this pipeline, and it lists leftover IAM roles and policies. Delete the listed roles and policies in the IAM console after you check each name.

```bash
bash tools/cleanup-leftovers.sh
```

**Step 2. Use a new GitHub repo.** Make a new empty private repo named `gitleaks-demo-app`. Do not reuse the repo from the manual path, because its history holds fake keys. Push the demo app to it with the commands from "Before you start".

**Step 3. Create a GitHub token.** The OAuth action needs a personal access token. On GitHub, create a classic personal access token with the `repo` scope and a short expiry. Polling does not need webhook access, so no other scope is needed. Copy it once.

<!-- UNVERIFIED: GitHub token page wording -->

**Step 4. Store the token in Secrets Manager.** Never put the token in the template or in the repo. Save it in a file outside the repo, create the secret from that file, and delete the file:

```bash
# Put this one line in ~/gitleaks-token.json  ->  {"token":"<YOUR_GITHUB_TOKEN>"}
aws secretsmanager create-secret --name gitleaks-demo/github-token \
  --secret-string file://$HOME/gitleaks-token.json && rm $HOME/gitleaks-token.json
```

**Step 5. Deploy the stack.** It creates the buckets, the log group, the CodeBuild project, both roles and the pipeline. It needs IAM capability because it names the roles. The template reads the token from the secret when it deploys. Its roles already have the access you added by hand in Part 3.

```bash
aws cloudformation deploy \
  --template-file cloudformation/gitleaks-demo-stack.yaml \
  --stack-name gitleaks-demo-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubOwner=<YOUR_USER> \
  --region us-east-1
```

**Step 6. Run the tests.** The pipeline starts by itself. Run Tests 1 to 6 from "Part 4: Run the tests" in the manual approach. The `git` commands are the same, and the results are the same. The pipeline polls GitHub, so a run can start a little after your push. If nothing starts within a minute or two, start it by hand:

```bash
aws codepipeline start-pipeline-execution --name gitleaks-demo-pipeline
```

<!-- UNVERIFIED: that polling starts runs on this V2 pipeline -->

**Checks from a terminal.** Use these instead of the console checks in the tests.

```bash
# Stage status
aws codepipeline get-pipeline-state --name gitleaks-demo-pipeline \
  --query 'stageStates[].[stageName,latestExecution.status]' --output text

# Follow the scan log
aws logs tail /aws/codebuild/gitleaks-demo-scan --follow

# Which release is on the site, and how many versions of the page exist
aws s3 cp s3://$SITE/index.html - | grep Release
aws s3api list-object-versions --bucket $SITE --query 'Versions[].[Key,VersionId,LastModified]' --output text

# The saved reports
aws s3 ls s3://$ARTIFACTS/reports/ --recursive

# The fingerprint of a finding, from the last hour of the scan log
aws logs tail /aws/codebuild/gitleaks-demo-scan --since 1h | grep fingerprint=
```

## Teardown for the automated approach

1. Empty both buckets first. CloudFormation cannot delete a bucket that has objects in it.

   ```bash
   bash tools/empty-bucket.sh $SITE && bash tools/empty-bucket.sh $ARTIFACTS
   ```

2. Delete the stack and wait. It owns the buckets, the log group, the CodeBuild project, both roles and the pipeline:

   ```bash
   aws cloudformation delete-stack --stack-name gitleaks-demo-stack && \
   aws cloudformation wait stack-delete-complete --stack-name gitleaks-demo-stack
   ```

3. Delete the secret. Secrets Manager keeps a deleted secret for a recovery period unless you skip it:

   ```bash
   aws secretsmanager delete-secret --secret-id gitleaks-demo/github-token --force-delete-without-recovery
   ```

4. On GitHub: delete the personal access token you created, and delete the repo `gitleaks-demo-app`.

## Troubleshooting

**The scan passes, but I expected it to block my fake key.**
The key does not match the rule. Two causes show up in practice. One: the key has a character outside `A-Z` and `2-7`, for example a `9`. The rule ignores it. Two: the key ends in `EXAMPLE`, like the key in AWS documentation. The default rule allows it on purpose. Use `bash tools/new-fake-key.sh`, which makes a key with the right shape.

**The Build stage fails with `Error calling startBuild: ... is not authorized to perform: codebuild:StartBuild`.**
The pipeline's service role has no policy that allows it to start the CodeBuild project. In the console path, add the pipeline policy from Part 3 to the role named in the error message. Then choose **Release change**. The CloudFormation path does not need this, because the template gives its pipeline role this permission.

**The Build stage fails at DOWNLOAD_SOURCE with `AccessDenied ... is not authorized to perform: s3:GetObject`.**
The CodeBuild role cannot read the source zip from the artifact bucket. In the console path, the wizard gives the role access only to its own default bucket, not to the bucket with the fixed name. Add the CodeBuild policy from Part 3 to the role named in the error message. Then choose **Release change**. The CloudFormation path does not need this, because the template gives its CodeBuild role the same access.

**The Deploy stage fails with `You do not have sufficient permissions to call s3.putObject for the deployment bucket`.**
The pipeline's service role cannot write to the site bucket. Add the pipeline policy from Part 3 to the role named in the error message. It allows `s3:PutObject`, `s3:PutObjectAcl` and `s3:PutObjectVersionAcl` on the site bucket, which is what the error text asks for. Then choose **Release change**. The CloudFormation path does not need this, because the template gives its pipeline role the same access.

**I deleted the file with the key, and the pipeline passes.**
This is how a files-only scan works. The key is still in the Git history. See Test 3.

**`InvalidStructureException: Triggers for connections must reference a CodeStarSourceConnection action.`**
This appears when you change the Source action of an existing pipeline from GitHub (via GitHub App) to GitHub (via OAuth app). The pipeline still has a push trigger that belongs to the connection action. Create the pipeline with the OAuth action from the start, as in Part 2, and you will not see this. To fix an existing pipeline, remove the trigger first. The console does not show it, so this fix needs a terminal. Write the files to `/tmp`, so `git add -A` never commits them:

```bash
aws codepipeline get-pipeline --name gitleaks-demo-pipeline > /tmp/pipeline.json
python3 - <<'EOF'
import json
d = json.load(open('/tmp/pipeline.json'))
d.pop('metadata', None)
d['pipeline'].pop('triggers', None)
json.dump(d, open('/tmp/pipeline-new.json', 'w'), indent=2)
EOF
aws codepipeline update-pipeline --cli-input-json file:///tmp/pipeline-new.json
```

<!-- UNVERIFIED: that removing the trigger lets the OAuth action save -->

**`ERROR: this is not a Git repository. Set the Source action to Full clone.`**
Your repo holds an old copy of `scripts/secret-scan.sh`. The current script scans files and does not check for a Git repository. Copy the current `demo-app/scripts/secret-scan.sh` from this guide's repo into your `gitleaks-demo-app` repo, then commit and push.

**`bash: /tools/new-fake-key.sh: No such file or directory`.**
The `GUIDE` variable is not set, so the shell leaves it empty. Set it to the full path of this guide's folder, for example `GUIDE=$HOME/Downloads/aws-gitleaks-secret-gate`. Variables last only for the terminal window where you set them, so set it again in a new window. Also check that you are in the `gitleaks-demo-app` folder and not in this guide's folder. If you run the test commands in the guide's own repo, the fake key ends up in the wrong repo.

**`zsh: permission denied: ./tools/new-fake-key.sh`**
A zip file drops the execute bit. Run the helper scripts with `bash tools/new-fake-key.sh`.

## Conclusion

You built a pipeline that scans every commit for secrets before it deploys, and you proved it three ways: the page did not change after a blocked run, the log did not show the secret, and the report in S3 is redacted. You also saw the limits. A files-only scan lets a deleted key through while it stays in the Git history, and an ignore fingerprint covers a place in a file, not one secret.

Use this as one layer. Run Gitleaks on the developer's machine before each commit as well, so most secrets never reach GitHub. If you want the pipeline to read the history too, switch the Source action to GitHub (via GitHub App) with the Full clone output format, and scan with `gitleaks git`.

The code, template and helper scripts are in the GitHub repo for this guide: https://github.com/Gbengard/aws-gitleaks-secret-gate
