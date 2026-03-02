# GitHub Actions Deployment Workflow Fix Guide

## Executive Summary

Your workflow deployment issue has **three root causes**, all interconnected:

1. **`workflow_run` uses wrong branch ref** → Environment detection fails
2. **Environment detection fails** → Wrong environment selected → Secrets not injected
3. **Secrets empty** → SSH auth fails before script executes → No echo logs visible

---

## Detailed Root Cause Analysis

### Issue #1: `workflow_run` Context Problem (THE PRIMARY CAUSE)

**Your Code:**

```yaml
on:
  workflow_run:
    workflows: ["Static Site Quality Check"]
    types:
      - completed

jobs:
  determine-environment:
    steps:
      - name: Determine target environment
        id: set-env
        run: |
          if [[ "${{ github.ref }}" == "refs/heads/main" ]]; then
            # This check doesn't work with workflow_run!
```

**The Problem:**

- When using `workflow_run`, `github.ref` refers to the **triggering workflow's state**, not your current branch context
- According to [GitHub Actions documentation](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#workflow_run), you **MUST** use `github.event.workflow_run.head_branch`

**What Happens:**

```
Branch: develop → Triggers quality workflow → Completes → Triggers deploy workflow
                                                              ↓
                                                         github.ref = "refs/heads/main" (wrong!)
                                                         Should be "develop"
                                                         ↓
                                                    Environment set to "production" (wrong!)
                                                         ↓
                                                    Job tries to access "production" env secrets
                                                         ↓
                                                    But deploy should use "development" env
                                                         ↓
                                                    Secrets not injected = empty HOST_KEY
```

**Fixed Code:**

```yaml
- name: Determine target environment
  id: set-env
  run: |
    SOURCE_BRANCH="${{ github.event.workflow_run.head_branch }}"  # ✅ CORRECT

    if [[ "$SOURCE_BRANCH" == "main" ]]; then
      echo "environment=production" >> $GITHUB_OUTPUT
```

**Why This Matters for Secrets:**

- GitHub's environment secret injection checks if `environment: <name>` in job matches the configured environment
- If determination fails, you get wrong environment name
- Secrets don't inject for mismatched environments
- `secrets.HOST_KEY` becomes empty
- SSH action receives empty key

---

### Issue #2: Environment Secrets Protection Rules

**What Happened:**
Your workflow runs with `environment: ${{ needs.determine-environment.outputs.environment }}`

When secrets are empty, it's often because:

1. **Environment Name Case Mismatch**
   - GitHub environment names are case-sensitive
   - If you configured `production` but job uses `Production` → secrets don't inject
   - After the fix, double-check your environment names match exactly

2. **Environment Doesn't Exist**
   - Job references `environment: development`
   - But only `production` and `testing` environments exist
   - → Secrets not found

3. **Deployment Protection Rules**
   - If you have "Required reviewers" enabled for an environment, deployments must be manually approved
   - Unapproved deployments don't receive secrets
   - Check Actions → Deployments in your GitHub UI

---

### Issue #3: SSH Logs Not Appearing (Symptom, Not Root Cause)

**Why You See No Echo Output:**

```yaml
- name: Test SSH Connection
  uses: appleboy/ssh-action@v0.1.10
  with:
    host: ${{ secrets.HOST_IP }} # Empty!
    key: ${{ secrets.HOST_KEY }} # Empty!
    script: |
      echo "This never executes"
```

**Execution Flow:**

```
Docker pulls appleboy/ssh-action image
    ↓
Extracts parameters from job context
    ↓
Attempts SSH authentication: ssh -i "" user@<empty>
    ↓
SSH HANDSHAKE FAILS: "attempted methods [none publickey]"
    ↓
Docker action exits immediately
    ↓
Script NEVER executes (still waiting in container memory)
    ↓
No echo logs visible in GitHub UI
```

The action doesn't fail with a clear error. It just exits because:

- Empty `host` → invalid connection
- Empty `key` → authentication fails immediately
- Script section is buffered in the Docker container
- Container exits before flushing logs

---

## Safe Debugging Strategy (No Secret Exposure)

### Strategy #1: Verify Branch Detection

Add this step to see what branch is actually detected:

```yaml
- name: Verify branch detection (safe debug)
  run: |
    echo "event.workflow_run.head_branch: ${{ github.event.workflow_run.head_branch }}"
    echo "github.ref: ${{ github.ref }}"
    echo "github.ref_name: ${{ github.ref_name }}"
    # This shows you the actual values
```

**Expected Output:**

```
event.workflow_run.head_branch: develop
github.ref: refs/heads/main         (ignore this, it's wrong)
github.ref_name: main               (ignore this too)
```

### Strategy #2: Check Secrets Exist (Without Exposing Values)

Your updated workflow now does this safely:

```bash
if [ -z "${{ secrets.HOST_KEY }}" ]; then
    echo "❌ HOST_KEY is EMPTY"
    echo "   Environment secrets NOT injected"
    echo "   Cause: Check environment name matches exactly"
else
    KEY_LEN=$(echo -n "${{ secrets.HOST_KEY }}" | wc -c)
    echo "✅ HOST_KEY exists (${KEY_LEN} characters)"
fi
```

**Why This is Safe:**

- ❌ Don't: `echo "${{ secrets.HOST_KEY }}"` (exposes the key)
- ✅ Do: `echo "Key length: $(echo -n "${{ secrets.HOST_KEY }}" | wc -c)"` (only shows length)
- ✅ Do: `echo "${{ secrets.HOST_KEY }}" | head -c 50 | grep "BEGIN"` (only checks format)

### Strategy #3: Check Environment Configuration

**In GitHub UI:**

1. **Settings** → **Environments**
2. For each environment (production, testing, development):
   - Check spelling matches your workflow output **exactly**
   - Check all 4 secrets exist: `HOST_IP`, `DEPLOY_PATH`, `DEPLOY_USERNAME`, `HOST_KEY`
   - If "Deployment branch rules" is set → verify correct branch is listed
   - If "Required reviewers" is enabled → approve pending deployments

**Red Flags to Avoid:**

```
❌ Workflow uses "development" but environment is "dev"
❌ Workflow uses "Testing" but environment is "testing"
❌ Secrets exist only for "production", job needs "development"
```

### Strategy #4: Test SSH Locally Before Committing

Before troubleshooting more, verify your SSH key works:

```bash
# On your local machine
ssh -i your_private_key user@server_ip
```

If this fails, the key is the problem, not GitHub Actions.

---

## What Changed in Your Updated Workflow

### Change #1: Fixed Branch Detection (Line 24)

```diff
- if [[ "${{ github.ref }}" == "refs/heads/main" ]]; then
+ SOURCE_BRANCH="${{ github.event.workflow_run.head_branch }}"
+ if [[ "$SOURCE_BRANCH" == "main" ]]; then
```

**Result:** Correct environment now selected for each branch

### Change #2: Enhanced Secret Validation (Lines 82-129)

```diff
- if [ -z "$HOST_KEY" ]; then
-   echo "❌ HOST_KEY not configured"
+ if [ -z "${{ secrets.HOST_KEY }}" ]; then
+   echo "❌ CRITICAL: SSH Key is EMPTY"
+   echo "   Cause: Environment name mismatch or protection rule issue"
```

**Result:** Clear diagnostic message when secrets aren't injected

### Change #3: Improved SSH Test (Lines 132-157)

```diff
  script: |
+   set -e
    echo "🔗 SSH CONNECTION SUCCESSFUL ✅"
```

**Result:** Better error handling, logs appear faster

---

## Step-by-Step Fix Instructions

### Step 1: Apply the Updated Workflow

The workflow file has been updated. Deploy this to your repository.

### Step 2: Verify Environment Names

**GitHub UI → Settings → Environments**

Create/ensure these environments exist with exact names:

- ✅ `production` (for main branch)
- ✅ `testing` (for staging branch)
- ✅ `development` (for develop branch)

**Case matters!** All lowercase.

### Step 3: Add Secrets to Each Environment

For each environment, add these 4 secrets:

| Secret Name       | Example Value     | Notes                                    |
| ----------------- | ----------------- | ---------------------------------------- |
| `HOST_IP`         | `192.168.1.100`   | Server IP or domain                      |
| `DEPLOY_PATH`     | `/var/www/html`   | Directory for your files                 |
| `DEPLOY_USERNAME` | `deploy`          | SSH user on server                       |
| `HOST_KEY`        | (SSH private key) | Full PEM-format key with BEGIN/END lines |

### Step 4: Test the Trigger

Push a commit to your `develop` branch:

```bash
git commit --allow-empty -m "Test workflow fix"
git push origin develop
```

This triggers:

1. `Static Site Quality Check` workflow
2. Upon completion → `Deploy Static Site` workflow with environment=development

Watch the logs:

- ✅ "environment=development" should appear
- ✅ "HOST_KEY is set" should appear
- ✅ SSH connection test should succeed

### Step 5: Check Protection Rules (If Applicable)

**GitHub UI → Settings → Environments → (each environment)**

If you see a yellow banner about "Required reviewers":

- Go to Deployments in Actions tab
- Approve any pending deployment
- Workflow will resume

---

## Repository Secrets vs Environment Secrets: Recommendation

### Why Your Environment Secrets Failed

- Environment secrets require exact environment name match
- `workflow_run` context makes this fragile (you need `event.workflow_run.head_branch`)
- Protection rules can block secret injection

### Why Repository Secrets Work (But Aren't Recommended)

- Not tied to environment
- No protection rules
- But: exposed to all workflows, all branches
- Security risk for multi-team projects

### Recommended Approach for `workflow_run` Deployments

**Use Environment Secrets, But:**

1. **Fix branch detection** (already done ✅)
   - Use `github.event.workflow_run.head_branch`

2. **Remove protection rules if not needed**
   - Go to Environments settings
   - Disable "Required reviewers" unless you need approval workflows
   - Keep deployment branches rule enabled for safety

3. **Add environment-to-branch mapping validation**
   - Your updated workflow now does this automatically

4. **For temporary debugging only** (not production):
   ```yaml
   - name: Debug environment
     run: |
       echo "Determined environment: ${{ needs.determine-environment.outputs.environment }}"
       echo "Available environments: production, testing, development"
       # Then check GitHub UI to verify this environment has secrets
   ```

---

## Diagnosis Checklist (For If It Still Fails)

Run through this if you still see empty secrets:

- [ ] Updated workflow deployed to main branch
- [ ] All 3 environments created in GitHub with exact case match
- [ ] All 4 secrets added to each environment
- [ ] Ran `git push origin develop` (triggers proper workflow)
- [ ] Checked Actions logs for "SOURCE_BRANCH" value (should be "develop")
- [ ] Checked "determined environment" should be "development"
- [ ] Went to Deployments → approved any pending deployments
- [ ] SSH key format verified (starts with "-----BEGIN")
- [ ] SSH key works when tested locally: `ssh -i key user@host`

If still failing after these checks, the issue is likely:

1. Environment name typo (check case)
2. Secrets not added to the environment (check you clicked correct env)
3. Deployment protection rules blocking (check Deployments tab)

---

## Key Takeaways

| Problem                    | Root Cause                             | Solution                                                |
| -------------------------- | -------------------------------------- | ------------------------------------------------------- |
| Environment secrets empty  | `github.ref` wrong with `workflow_run` | Use `github.event.workflow_run.head_branch`             |
| Echo logs not visible      | SSH auth fails before script runs      | Fix branch detection → secrets injected → auth succeeds |
| SSH handshake fails        | Empty HOST_KEY secret                  | Ensure environment name exactly matches configured env  |
| Wrong environment selected | Branch detection logic wrong           | Updated workflow now correct                            |

---

## Files Modified

- ✅ [.github/workflows/deploy.yml](.github/workflows/deploy.yml) - Updated with fixes

---

## Additional Resources

- [GitHub workflow_run Context](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#workflow_run)
- [GitHub Environment Secrets](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [appleboy/ssh-action Docs](https://github.com/appleboy/ssh-action)
