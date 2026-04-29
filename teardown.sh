#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  Team Alpha Chatbot — Teardown Script
#  Deletes all resources created by deploy.sh
#
#  Usage:
#    bash teardown.sh chatbot-deployer
#    bash teardown.sh                    (prompts for profile)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Arguments ──────────────────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
  export AWS_PROFILE="$1"
elif [[ -z "${AWS_PROFILE:-}" ]]; then
  echo ""
  echo "  No AWS_PROFILE set. Enter the profile name to use"
  echo "  (e.g. chatbot-deployer):"
  read -r AWS_PROFILE
  export AWS_PROFILE
fi

ENVIRONMENT="${2:-dev}"
REGION="us-east-1"
STACK_NAME="TeamAlpha-chatbot"

# ── Colours ────────────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; NC='\033[0m'

echo ""
echo -e "${R}============================================${NC}"
echo -e "${R} Team Alpha Chatbot - TEARDOWN${NC}"
echo -e "${R} Environment: ${ENVIRONMENT}${NC}"
echo -e "${R} Region:      ${REGION}${NC}"
echo -e "${R} Profile:     ${AWS_PROFILE}${NC}"
echo -e "${R}============================================${NC}"
echo ""

# ── Confirm ────────────────────────────────────────────────────────────────
echo -e "${R}WARNING: This will delete ALL chatbot resources including:${NC}"
echo "  - CloudFormation stack (VPC, Aurora, Lambda, API Gateway, CloudFront)"
echo "  - S3 buckets (docs + frontend) and all their contents"
echo "  - Bedrock Knowledge Base, Agent, and Guardrail"
echo "  - Secrets Manager secrets"
echo ""
read -p "Are you sure? Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "  Teardown cancelled."
  exit 0
fi
echo ""

# -------------------------------------------
# Step 1: Get Account ID
# -------------------------------------------
echo -e "${Y}[1/4] Getting AWS account info...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo -e "${G}  Account: ${ACCOUNT_ID}${NC}"

DOCS_BUCKET="team-alpha-docs-${ACCOUNT_ID}"
FRONTEND_BUCKET="team-alpha-frontend-${ACCOUNT_ID}"

# -------------------------------------------
# Step 2: Empty S3 buckets
# -------------------------------------------
echo -e "${Y}[2/4] Emptying S3 buckets...${NC}"

if aws s3api head-bucket --bucket "$DOCS_BUCKET" --region "$REGION" 2>/dev/null; then
  aws s3 rm "s3://${DOCS_BUCKET}" --recursive --region "$REGION"
  echo -e "${G}  Emptied: ${DOCS_BUCKET}${NC}"
else
  echo "  Bucket ${DOCS_BUCKET} not found, skipping"
fi

if aws s3api head-bucket --bucket "$FRONTEND_BUCKET" --region "$REGION" 2>/dev/null; then
  aws s3 rm "s3://${FRONTEND_BUCKET}" --recursive --region "$REGION"
  echo -e "${G}  Emptied: ${FRONTEND_BUCKET}${NC}"
else
  echo "  Bucket ${FRONTEND_BUCKET} not found, skipping"
fi

# -------------------------------------------
# Step 3: Delete CloudFormation stack
# -------------------------------------------
echo -e "${Y}[3/4] Deleting CloudFormation stack...${NC}"
echo "  This may take 10-15 minutes (Aurora deletion)..."

aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

echo "  Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"

echo -e "${G}  Stack deleted${NC}"

# -------------------------------------------
# Step 4: Delete S3 buckets (now empty)
# -------------------------------------------
echo -e "${Y}[4/4] Deleting S3 buckets...${NC}"

if aws s3api head-bucket --bucket "$DOCS_BUCKET" --region "$REGION" 2>/dev/null; then
  aws s3api delete-bucket --bucket "$DOCS_BUCKET" --region "$REGION"
  echo -e "${G}  Deleted: ${DOCS_BUCKET}${NC}"
fi

if aws s3api head-bucket --bucket "$FRONTEND_BUCKET" --region "$REGION" 2>/dev/null; then
  aws s3api delete-bucket --bucket "$FRONTEND_BUCKET" --region "$REGION"
  echo -e "${G}  Deleted: ${FRONTEND_BUCKET}${NC}"
fi

# -------------------------------------------
# Done
# -------------------------------------------
echo ""
echo -e "${G}============================================${NC}"
echo -e "${G} Teardown Complete!${NC}"
echo -e "${G}============================================${NC}"
echo ""
echo "  All Team Alpha Chatbot resources have been deleted."
echo ""

# Clean up outputs file
rm -f deployment-outputs.txt
