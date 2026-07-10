# Interview Prep — Talking About the CloudPipe Project

## The 30-second version (recruiter / non-technical)

> "I built an automated deployment pipeline for a web agency that was uploading website files to production by hand — 15 to 20 minutes per change, and one missed file once broke a client's contact form for hours. I set it up so that when a developer saves their code to GitHub, it automatically goes live in about a minute, with an immediate alert if anything fails. Deploy time went from 20 minutes to under 2, and the 'forgotten file' problem became impossible. It runs on AWS for about a dollar a month."

Notice the structure: problem → what you did → measurable outcome. No tool names needed until they ask.

## The 2-minute version (hiring manager / technical screen)

> "The client hosted static sites and deployed manually via file upload. I designed a pipeline where a push to main triggers GitHub Actions, which authenticates to AWS with a least-privilege IAM identity, syncs the site to a private S3 bucket with `s3 sync --delete` — so the bucket always exactly mirrors the repo — and then invalidates the CloudFront cache so users see the new version immediately.
>
> A few decisions I'd highlight: the bucket is fully private with Origin Access Control, so all traffic goes through CloudFront — that gives HTTPS, edge caching, and no publicly readable bucket. The deploy credentials can only touch that one bucket and that one distribution, so a leaked secret has minimal blast radius. And the whole infrastructure is a single CloudFormation template, so the environment is reviewable, version-controlled, and rebuildable in minutes.
>
> Rollback is just reverting a commit — the pipeline redeploys the previous state. Failure notifications come free from GitHub: red X on the commit plus an email to the author."

## Likely follow-up questions and strong answers

**"Why S3 and not a web server?"**
The sites are static. A server means paying for idle compute, OS patching, and a single point of failure — to serve files. S3 gives 99.99% availability, managed by AWS, for cents. Right-sizing the solution to the problem is the point.

**"Why CloudFront if S3 can host websites directly?"**
Three reasons: S3 website endpoints don't support HTTPS (dealbreaker for client sites with forms), CloudFront caches at edge locations so the sites are fast globally, and it lets me keep the bucket completely private via Origin Access Control.

**"Why do you invalidate the cache after deploying?"**
Because CloudFront edges hold cached copies of the old files. Without invalidation the deploy 'succeeds' but visitors keep getting stale content until TTLs expire. `create-invalidation --paths "/*"` forces edges to refetch. It's coarse, but at this scale it's the right simplicity tradeoff — the first 1,000 invalidation paths a month are free.

**"What does `--delete` do on the sync, and why is it important?"**
It removes files from S3 that no longer exist in the repo, making the bucket an exact mirror of git. Without it you accumulate orphaned files, and worse, git stops being the source of truth for what's in production.

**"What's the weakest part of this design?"** *(they're testing self-awareness)*
The long-lived IAM access keys stored as GitHub secrets. The production-grade upgrade is GitHub's OIDC federation into an IAM role — short-lived credentials per workflow run, nothing to rotate or leak. I kept keys for simplicity at the client's scale, but I know the migration path and it's about 30 minutes of work.

**"How would you add a staging environment?"**
Second S3 bucket + CloudFront distribution from the same template with a parameter, and a workflow trigger on a `staging` branch. Merging staging → main promotes to production. The template is parameterized, so it's mostly a workflow change.

**"What happens if the deploy fails halfway through the sync?"**
S3 sync isn't atomic — some files could be new while others are old for a few seconds. For static sites this window is tiny and the fix is re-running the workflow. If atomicity mattered, I'd version the deploys (upload to a new prefix, then flip the CloudFront origin path) — but that's complexity this client doesn't need yet.

**"How do you handle rollbacks?"**
`git revert` and push. The pipeline treats every commit the same way, so rolling back is just deploying an older state. No snowflake rollback procedure to document or forget.

**"How much does this cost?"**
About $1–2/month: S3 storage is pennies, CloudFront's free tier covers small-business traffic, GitHub Actions' free tier covers the deploy minutes, CloudFormation is free. I can say that precisely because I checked — cost awareness is part of the design.

## STAR story (behavioral format)

- **Situation:** Web agency deploying manually; a missed file broke a client's contact form for hours; every change cost 15–20 developer-minutes.
- **Task:** Design and implement an automated deployment pipeline that was fast, reliable, and simple enough for a small team to own.
- **Action:** Built a GitHub Actions → S3 → CloudFront pipeline; defined all infrastructure in CloudFormation; scoped IAM to least privilege; added cache invalidation and failure notifications; documented setup, rollback, and troubleshooting; tested the failure path deliberately.
- **Result:** Deploys went from 15–20 minutes of manual work to under 2 minutes hands-off; the missing-file failure mode is structurally eliminated; the team gets immediate failure alerts; total infra cost ~$1–2/month.

## Traps to avoid

- Don't recite tools; lead with the problem. "I used GitHub Actions and S3" is forgettable. "Deploys took 20 error-prone minutes; I made them automatic" is a story.
- Don't oversell it. It's a straightforward pipeline — own that. "The value was matching the solution to the client's actual scale" reads as senior judgment, not smallness.
- Know your one incident cold: the forgotten JS file. Concrete failure stories are what interviewers remember.
- Be ready for "what would you do differently" — that's the OIDC answer, already loaded.
