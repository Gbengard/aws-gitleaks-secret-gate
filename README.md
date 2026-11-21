# Block leaked secrets in a CI/CD pipeline with Gitleaks

A CodePipeline pipeline that scans the full Git history for secrets before it deploys. If Gitleaks finds one, the Scan stage fails and the Deploy stage never starts.

The full walkthrough is in [guide.md](guide.md). It covers the console path and the CloudFormation path, with a teardown for each.

## What is in this repo

```
guide.md                               the full guide
cloudformation/01-base-stack.yaml      site bucket, artifact bucket, GitHub connection (PENDING until you authorize it)
cloudformation/02-pipeline-stack.yaml  log group, CodeBuild project, roles, pipeline
demo-app/                              copy this into your own throwaway GitHub repo
  site/index.html                      the page that gets deployed
  buildspec.yml                        runs the scan, then hands the site files to Deploy
  scripts/secret-scan.sh               installs a pinned Gitleaks, scans the history, saves a redacted report
  .gitleaks.toml                       default rules plus one custom rule
tools/                                 run with bash, on your computer
  new-fake-key.sh                      prints a random string shaped like an AWS access key ID (not a real key)
  empty-bucket.sh                      removes every object version so a bucket can be deleted
  cleanup-leftovers.sh                 deletes the log group and lists leftover IAM roles
```

## Important

The tests put a fake key into the Git history. Use a separate, private, throwaway GitHub repo for `demo-app/`, and never commit a fake key to this repo.

## Cost

A few build minutes per run. CodeBuild has a free tier and a 10 minute timeout is set on the project. Check the CodeBuild and CodePipeline pricing pages before you deploy. Delete everything when you finish, using the teardown sections in the guide.
