#!/usr/bin/env bash
#
# GitHub Actions Workflow Fix Verification Script
# Purpose: Verify that branch detection and secret injection are working correctly
# 
# Usage: ./verify-workflow-fix.sh
#

set -e

echo "🔍 GitHub Actions Workflow Fix Verification"
echo "============================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✅ PASS${NC}: $2"
    else
        echo -e "${RED}❌ FAIL${NC}: $2"
    fi
}

print_info() {
    echo -e "${BLUE}ℹ️  INFO${NC}: $1"
}

print_warning() {
    echo -e "${YELLOW}⚠️  WARNING${NC}: $1"
}

FAILURES=0

# Check 1: Verify Git is available
if command -v git &> /dev/null; then
    print_status 0 "Git is installed"
else
    print_status 1 "Git is not installed"
    FAILURES=$((FAILURES + 1))
fi

# Check 2: Verify we're in a git repository
if git rev-parse --git-dir > /dev/null 2>&1; then
    print_status 0 "Currently in a Git repository"
    REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
    print_info "Repository: $REPO_NAME"
else
    print_status 1 "Not in a Git repository"
    FAILURES=$((FAILURES + 1))
    exit 1
fi

# Check 3: Verify workflow file exists
WORKFLOW_FILE=".github/workflows/deploy.yml"
if [ -f "$WORKFLOW_FILE" ]; then
    print_status 0 "Deploy workflow file exists"
else
    print_status 1 "Deploy workflow file missing: $WORKFLOW_FILE"
    FAILURES=$((FAILURES + 1))
fi

# Check 4: Verify workflow contains the fix
if grep -q "github.event.workflow_run.head_branch" "$WORKFLOW_FILE" 2>/dev/null; then
    print_status 0 "Workflow contains correct branch detection fix"
else
    print_status 1 "Workflow missing fix: github.event.workflow_run.head_branch"
    print_warning "The workflow still uses github.ref instead of github.event.workflow_run.head_branch"
    FAILURES=$((FAILURES + 1))
fi

# Check 5: Verify environment configuration
echo ""
echo "🔐 Environment Configuration Check"
echo "===================================="

# Try to get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
print_info "Current branch: $CURRENT_BRANCH"

# Map branch to expected environment
case "$CURRENT_BRANCH" in
    main)
        EXPECTED_ENV="production"
        ;;
    staging)
        EXPECTED_ENV="testing"
        ;;
    develop|development)
        EXPECTED_ENV="development"
        ;;
    *)
        EXPECTED_ENV="unknown"
        print_warning "Current branch '$CURRENT_BRANCH' is not a primary branch (main/staging/develop)"
        ;;
esac

if [ "$EXPECTED_ENV" != "unknown" ]; then
    print_info "Expected environment: $EXPECTED_ENV"
    print_info "⚠️  Cannot verify GitHub environment secrets from CLI"
    echo ""
    echo "To verify environment setup, visit GitHub UI:"
    echo "  1. Go to your repository on GitHub.com"
    echo "  2. Settings → Environments"
    echo "  3. Verify environment exists: '$EXPECTED_ENV'"
    echo "  4. Verify these secrets are configured:"
    echo "     - HOST_IP"
    echo "     - DEPLOY_PATH"
    echo "     - DEPLOY_USERNAME"
    echo "     - HOST_KEY"
fi

# Check 6: Verify SSH key format (if available locally)
echo ""
echo "🔑 SSH Key Format Check"
echo "======================="

# Check if a local SSH key exists (common locations)
SSH_KEY_PATHS=(
    "$HOME/.ssh/id_rsa"
    "$HOME/.ssh/id_ed25519"
    "$HOME/.ssh/deployment_key"
)

KEY_FOUND=0
for KEY_PATH in "${SSH_KEY_PATHS[@]}"; do
    if [ -f "$KEY_PATH" ]; then
        print_info "Found SSH key: $KEY_PATH"
        
        # Check if key is encrypted
        if grep -q "ENCRYPTED" "$KEY_PATH"; then
            print_warning "SSH key is encrypted (has passphrase)"
            print_warning "GitHub Actions deployments typically need unencrypted keys"
        else
            print_status 0 "SSH key appears to be unencrypted"
        fi
        
        # Verify key format
        if grep -q "BEGIN.*PRIVATE KEY" "$KEY_PATH"; then
            print_status 0 "SSH key has valid PEM format"
        else
            print_status 1 "SSH key format may be incorrect"
            FAILURES=$((FAILURES + 1))
        fi
        
        # Show key length
        KEY_LENGTH=$(wc -c < "$KEY_PATH")
        print_info "SSH key size: $KEY_LENGTH bytes"
        
        if [ "$KEY_LENGTH" -lt 1000 ]; then
            print_warning "SSH key seems unusually small"
        fi
        
        KEY_FOUND=1
        break
    fi
done

if [ $KEY_FOUND -eq 0 ]; then
    print_warning "No local SSH key found in standard locations"
    print_info "If using GitHub-generated deployment key, this is normal"
fi

# Check 7: Verify workflow syntax
echo ""
echo "📋 Workflow Syntax Check"
echo "========================"

# Basic YAML validation (just check for obvious issues)
if grep -q "^jobs:" "$WORKFLOW_FILE"; then
    print_status 0 "Workflow has 'jobs' section"
else
    print_status 1 "Workflow missing 'jobs' section"
    FAILURES=$((FAILURES + 1))
fi

if grep -q "determine-environment:" "$WORKFLOW_FILE"; then
    print_status 0 "Workflow has 'determine-environment' job"
else
    print_status 1 "Workflow missing 'determine-environment' job"
    FAILURES=$((FAILURES + 1))
fi

if grep -q "deploy:" "$WORKFLOW_FILE"; then
    print_status 0 "Workflow has 'deploy' job"
else
    print_status 1 "Workflow missing 'deploy' job"
    FAILURES=$((FAILURES + 1))
fi

# Final summary
echo ""
echo "======================================"
echo "✨ Verification Summary"
echo "======================================"

if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}✅ All checks passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Verify environment secrets in GitHub UI (Settings → Environments)"
    echo "  2. Push to develop/staging/main branch to trigger workflow"
    echo "  3. Check Actions tab to see if deployment succeeds"
    echo ""
else
    echo -e "${RED}❌ $FAILURES check(s) failed${NC}"
    echo ""
    echo "Review the failures above and fix them"
    echo "Then run this script again"
    echo ""
fi

exit $FAILURES
