# Block leaked secrets in a CI/CD pipeline with Gitleaks

A CodePipeline pipeline that scans every commit for secrets before it deploys. If Gitleaks finds one, the Build stage fails and the Deploy stage never starts.

The demo app is one HTML page in an S3 bucket. The page shows a release number, so you can prove a block: after a blocked run, the page still shows the old release.

The full walkthrough is in [guide.md](guide.md). Read it first.

## Two ways to build it

| Approach | What you use | Where it is in the guide |
|---|---|---|
| Manual | The AWS console and `git`. No AWS CLI. | "Manual approach in the console" |
| Automated | CloudFormation and the AWS CLI v2 | "Automated approach with CloudFormation" |

Each approach has its own teardown. Both use the same fixed resource names, so finish the manual teardown before you start the automated approach.

You run the same six tests on both:

1. A clean commit passes and deploys.
2. A commit with a fake key is blocked.
3. Deleting the key file lets the pipeline pass, and the key stays in the Git history.
4. A false positive is allowed with a `gitleaks:allow` comment.
5. A custom rule catches your own token format.
6. A finding you have dealt with is accepted through `.gitleaksignore`.

## What is in this repo

```
guide.md                                 the full guide
cloudformation/gitleaks-demo-stack.yaml  buckets, log group, CodeBuild project, roles, pipeline
demo-app/                                copy this into your own throwaway GitHub repo
  site/index.html                        the page that gets deployed
  buildspec.yml                          runs the scan, then hands the site files to Deploy
  scripts/secret-scan.sh                 installs a pinned Gitleaks, scans the files, saves a redacted report
  .gitleaks.toml                         default rules plus one custom rule
tools/                                   run with bash, on your computer
  new-fake-key.sh                        prints a random string shaped like an AWS access key ID (not a real key)
  empty-bucket.sh                        removes every object version so a bucket can be deleted (automated approach)
  cleanup-leftovers.sh                   deletes the log group and leftover webhooks, lists leftover IAM roles (automated approach)
```

The files in `demo-app/` start with a dot or sit in subfolders. Show hidden files to see `.gitleaks.toml`.

## How to use it

1. Create a new, empty, private GitHub repo named `gitleaks-demo-app`.
2. Copy the contents of `demo-app/` into it, commit, and push to the `main` branch.
3. Follow the manual approach, then the automated approach, in the guide.
4. Run the test commands inside `gitleaks-demo-app`, not in this repo. Set `GUIDE` to the full path of this repo's folder, for example `GUIDE=$HOME/Downloads/aws-gitleaks-secret-gate`, so the tests can find `tools/new-fake-key.sh`.

Run the helper scripts with `bash tools/<name>.sh`. A zip file drops the execute bit.

## What it does not do

- It scans the files in each commit. It does not read the Git history, because the GitHub (via OAuth app) source gives the pipeline a zip of files only. Test 3 shows what that means. The guide explains how to scan the history with the GitHub App source and a full clone.
- It stops the deployment. It does not stop the push. By the time the pipeline sees a secret, it is already on GitHub. If a real key leaks, rotate it first.
- Rules find patterns, not every secret. Use this as one layer.

## Things to know before you start

- **Use a throwaway repo.** The tests put a fake key into the Git history, and history cannot be cleaned without rewriting it. Never commit a fake key to this repo. For the automated approach, use a new empty repo, not the one from the manual run.
- **The console wizard needs extra access.** The roles it creates cover only its own default bucket. Part 3 of the manual approach adds the missing permissions for the artifact bucket, the site bucket, and starting the CodeBuild project. The CloudFormation template already includes them.
- **Keep your copy of this repo current.** A stale copy has an old `scripts/secret-scan.sh`. The old script needs a Git repository and fails on the OAuth source.
- **The automated approach needs a GitHub token.** It is a personal access token stored in Secrets Manager. Create it only for this demo and delete it afterwards.

## Cost

A few build minutes per run. CodeBuild has a free tier and the project has a 10 minute timeout. Check the CodeBuild, CodePipeline and Secrets Manager pricing pages before you deploy. Delete everything when you finish, using the teardown sections in the guide.
