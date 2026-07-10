# CloudPipe Business Use Case

This walks through the project the way a consultant would think about it: problem first, tools second.

## 1. The problem, in plain terms

CloudPipe's developers deploy by manually uploading files to a server. Two failure modes:

**Human error.** A developer forgot one JavaScript file; the contact form broke for hours. Nobody noticed because there's no feedback loop — the "deployment system" is a human's memory.

**Wasted time.** 15–20 minutes per deploy, multiplied across every small change, across every developer. That time comes straight out of billable feature work.

**Who benefits:** developers (no more tedious, scary deploys), the business owner (more billable hours, fewer embarrassing outages), and CloudPipe's clients (their sites stay up and update faster).

The fix isn't "work more carefully" — it's removing the human from the repetitive part entirely. That's what CI/CD is: the machine does the same steps, the same way, every time.

## 2. Why these specific tools

| Decision | Why this | Why not the alternative |
|---|---|---|
| **S3 for hosting** | The sites are static (HTML/CSS/JS). S3 stores and serves files with 99.99% availability for pennies. No server to patch, scale, or crash at 2am. | EC2/traditional server = paying for idle compute + OS patching + a single point of failure, all to serve files. |
| **CloudFront in front of S3** | Gives us HTTPS (S3 website endpoints are HTTP-only — browsers flag that as insecure), global edge caching (fast for visitors anywhere), and lets the bucket stay private. | Public S3 website endpoint works but: no HTTPS, no caching, bucket must be world-readable. Fine for a demo, not for client sites. |
| **GitHub Actions for CI/CD** | The code already lives on GitHub, so the trigger is native — zero extra infrastructure, zero cost at this scale, and logs live next to the code. | Jenkins = a server to run and maintain (recreates the original problem). CodePipeline = works, but more setup and cost for no benefit here. |
| **Terraform for infrastructure** | The whole environment is version-controlled code, with `terraform plan` giving a full reviewable diff *before* anything changes. Rebuildable in minutes, no "click-ops" drift, and it's the most in-demand IaC skill. | Console clicking = undocumented, unrepeatable, impossible to code-review. CloudFormation = solid AWS-native alternative (an equivalent template is kept in `infrastructure/` for comparison) — the core difference is state: AWS manages it for you vs. Terraform's state file you own. |
| **IAM user with least privilege** | The pipeline gets exactly three abilities: write to this bucket, list this bucket, invalidate this distribution. If the keys ever leak, the blast radius is one website's files. | Admin keys = a leaked secret owns the whole AWS account. |

## 3. How the pipeline works, step by step

Follow one deployment through the system:

**Step 1 — Developer pushes to `main`.** Git is the single source of truth. Whatever is in the repo IS what's in production — no more "which version is live?" mystery.

**Step 2 — GitHub Actions triggers.** The `on: push: branches: [main]` block means GitHub itself watches for changes; we don't poll or run anything. The `paths` filter skips deploys when only docs or terraform changed — small optimization, faster feedback. (Real-world lesson: this filter meant the very first push showed "no runs yet" — the `workflow_dispatch` manual trigger was the escape hatch. Filters reduce noise but add trigger logic you have to reason about.)

**Step 3 — Runner checks out the code.** `actions/checkout@v4` clones the exact commit that was pushed onto a fresh Ubuntu VM. Fresh VM every time = no leftover state from previous deploys can cause weird behavior. (This is the CI/CD version of "works on my machine" — eliminated.)

**Step 4 — Runner authenticates to AWS.** `configure-aws-credentials` reads the access keys from GitHub **Secrets** — encrypted, masked in logs, never in the repo. This is the IAM box in the architecture diagram: AWS won't accept the `s3 sync` command from just anyone; the keys prove the runner is our authorized deploy user.

**Step 5 — `aws s3 sync website/ s3://bucket --delete`.** This is the heart of the fix. Sync compares the repo folder with the bucket and makes the bucket match exactly: new files uploaded, changed files replaced, deleted files removed (`--delete`). A human can forget a file; a diff algorithm cannot. The forgotten-JS-file incident is now structurally impossible.

**Step 6 — CloudFront invalidation.** CloudFront's edge servers cache files (that's their job — it's what makes the site fast). But after a deploy, those caches hold the OLD files. `create-invalidation --paths "/*"` tells every edge location to discard its copy and fetch fresh from S3. Without this step, deploys would "succeed" but users would keep seeing stale content for hours — a confusing bug that this one command prevents.

**Step 7 — Feedback.** Green check or red X on the commit, a run summary, and GitHub emails the author on failure. Success criterion #2 ("the team knows immediately if a deployment failed") is handled by the platform for free.

**Error handling is built into the model:** each step only runs if the previous one succeeded. If AWS auth fails, no sync is attempted; if sync fails, the failure notice runs and the logs show exactly which step and why. The pipeline can't half-forget things silently the way a human can.

## 4. The infrastructure decisions inside the Terraform config

**Private bucket + Origin Access Control.** All public access is blocked at the bucket (`aws_s3_bucket_public_access_block`). The bucket policy grants `s3:GetObject` only to CloudFront, and only to *our specific distribution* (the `AWS:SourceArn` condition). Why bother? Defense in depth: nobody can bypass CloudFront to scrape the bucket, and there's zero chance of the classic "accidentally public S3 bucket" headline.

**`redirect-to-https`.** Any visitor arriving over HTTP is redirected. Client sites handle contact forms — no excuse for unencrypted traffic in 2026.

**`PriceClass_100`.** CloudFront edges in US/EU only. CloudPipe's clients are local businesses; paying for edge locations in every continent buys nothing. Knowing which knobs NOT to turn is part of the job.

**Custom error responses → `index.html`.** S3 returns 403 for missing keys when accessed via OAC; mapping 403/404 to the index page gives clean behavior and supports single-page apps later.

**Why the IAM user has exactly 3+1 permissions.** Work backwards from what the pipeline runs: `s3 sync` needs Put/Delete/Get on objects and ListBucket on the bucket (to compute the diff); the invalidation needs `cloudfront:CreateInvalidation`. Nothing else. If you can't explain why a permission is in a policy, it shouldn't be there.

**Terraform-specific decisions worth knowing cold:**

- **Version pinning (`~> 5.0`).** The "pessimistic constraint": any 5.x provider, never 6.x without a deliberate upgrade. Unpinned providers are how "it worked yesterday" bugs happen.
- **State.** Terraform tracks what it manages in `terraform.tfstate` — the map between your config and real AWS resource IDs. Local state is fine for one person; a team uses an S3 backend with locking so two people can't `apply` at once. This is THE core difference from CloudFormation, where AWS stores state for you.
- **What gets committed.** `.terraform.lock.hcl` YES (pins exact provider versions, like a package lockfile). `terraform.tfstate` NEVER (can contain secrets in plaintext; it's gitignored).
- **Access keys created via CLI, not Terraform.** An `aws_iam_access_key` resource would write the secret key into the state file in plaintext. Keeping secrets out of state is standard practice.
- **Explicit `depends_on`.** Terraform infers creation order from references between resources, but the bucket policy and the public-access block don't reference each other — so the dependency is stated explicitly. Know why it's there.

## 5. Deploy it yourself (checklist)

1. Create GitHub repo `cloudpipe-deploy`, push this project to it. (Gotcha: pushing `.github/workflows/` requires a git credential with the `workflow` scope — `gh auth login` fixes it.)
2. In `terraform/`: `terraform init` (downloads the AWS provider — it's huge, be patient), `terraform plan` (expect: 8 to add, 0 to change, 0 to destroy), `terraform apply`.
3. `aws iam create-access-key --user-name cloudpipe-github-actions` — save both values immediately; the secret shows once.
4. Add the 4 repo secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_BUCKET` (output `bucket_name`), `CLOUDFRONT_DISTRIBUTION_ID` (output `distribution_id`).
5. Push a change to `website/index.html`. Watch the Actions tab. Open the `website_url` output.
6. **Test the failure path too:** temporarily break the `S3_BUCKET` secret, push, and confirm you get a red X and an email. Fix the secret and use "Re-run jobs" — no new commit needed, because the *code* was never wrong. Config and code are separate failure domains.
7. **Test rollback:** `git revert HEAD && git push` — confirm the old version comes back. Rollback = redeploying a previous commit; no special mechanism needed.

A pipeline you've never seen fail is a pipeline you don't understand.

## 6. What you'd do next (and why you didn't do it now)

These are deliberate scope decisions, not oversights — be ready to say so:

- **OIDC instead of access keys.** GitHub can federate directly into an IAM role, giving short-lived credentials per run. Strictly better security; slightly more setup. The access-key version matches the client's current maturity, and the migration is a ~30-minute change.
- **Remote Terraform state.** An S3 backend with locking, so state survives laptop loss and supports teamwork. Local state is the honest choice for a solo project — and knowing exactly when to graduate is the skill.
- **Staging environment.** A second bucket/distribution deployed from a `staging` branch (same config, different variable values). Skipped because the client's sites are simple and a broken deploy is fixed in one revert; add it when sites get complex enough that "test in prod" hurts.
- **HTML/link checking in the pipeline.** A validation step before sync would catch broken markup pre-deploy. Easy add once the basics have proven themselves.
- **Custom domain + ACM certificate.** Per-client domains via Route 53 + ACM on the CloudFront distribution. Left out because it's per-client configuration, not pipeline architecture.

The pattern: solve today's problem completely, know exactly what tomorrow's upgrade is, don't build it prematurely.
