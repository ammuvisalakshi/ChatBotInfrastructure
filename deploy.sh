#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  Team Alpha Chatbot — Deployment Script
#  Run from the root of ChatBotInfrastructure in Git Bash or bash.
#
#  Usage:
#    bash deploy.sh chatbot-deployer
#    bash deploy.sh                    (prompts for profile)
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
APP_CODE_PATH="../TeamAlphaChatbot"

# ── Colours ────────────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; NC='\033[0m'

echo ""
echo -e "${C}============================================${NC}"
echo -e "${C} Team Alpha Chatbot - Deployment${NC}"
echo -e "${C} Environment: ${ENVIRONMENT}${NC}"
echo -e "${C} Region:      ${REGION}${NC}"
echo -e "${C} Profile:     ${AWS_PROFILE}${NC}"
echo -e "${C}============================================${NC}"
echo ""

# -------------------------------------------
# Step 1: Get AWS Account ID
# -------------------------------------------
echo -e "${Y}[1/7] Getting AWS account info...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo -e "${G}  Account: ${ACCOUNT_ID}${NC}"

DOCS_BUCKET="team-alpha-docs-${ACCOUNT_ID}"
FRONTEND_BUCKET="team-alpha-frontend-${ACCOUNT_ID}"

# -------------------------------------------
# Step 2: Create docs bucket if needed
# -------------------------------------------
echo -e "${Y}[2/7] Ensuring docs bucket exists...${NC}"
if ! aws s3api head-bucket --bucket "$DOCS_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  Creating bucket: $DOCS_BUCKET"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$DOCS_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$DOCS_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi
# Enable CORS for browser uploads
aws s3api put-bucket-cors --bucket "$DOCS_BUCKET" --cors-configuration '{
  "CORSRules": [{"AllowedHeaders": ["*"], "AllowedMethods": ["PUT","POST"], "AllowedOrigins": ["*"], "MaxAgeSeconds": 3600}]
}' --region "$REGION"
echo -e "${G}  Docs bucket ready${NC}"

# -------------------------------------------
# Step 3: Package and upload Lambda functions
# -------------------------------------------
echo -e "${Y}[3/7] Packaging Lambda functions...${NC}"

# Resolve paths to Windows-style for PowerShell
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -W)
APP_CODE_WIN=$(cd "$APP_CODE_PATH" && pwd -W)
TEMP_WIN=$(cmd //c "echo %TEMP%" | tr -d '\r')

# Query Lambda
QUERY_ZIP="${TEMP_WIN}\\query-lambda.zip"
rm -f "$TEMP/query-lambda.zip" 2>/dev/null
powershell -Command "Compress-Archive -Path '${APP_CODE_WIN}\\backend\\query\\lambda_function.py' -DestinationPath '${QUERY_ZIP}' -Force"
aws s3 cp "${TEMP_WIN}\\query-lambda.zip" "s3://${DOCS_BUCKET}/lambda/query.zip" --region "$REGION"
echo -e "${G}  Query Lambda uploaded${NC}"

# Upload Lambda
UPLOAD_ZIP="${TEMP_WIN}\\upload-lambda.zip"
rm -f "$TEMP/upload-lambda.zip" 2>/dev/null
powershell -Command "Compress-Archive -Path '${APP_CODE_WIN}\\backend\\upload\\lambda_function.py' -DestinationPath '${UPLOAD_ZIP}' -Force"
aws s3 cp "${TEMP_WIN}\\upload-lambda.zip" "s3://${DOCS_BUCKET}/lambda/upload.zip" --region "$REGION"
echo -e "${G}  Upload Lambda uploaded${NC}"

# Cleanup
rm -f "${TEMP_WIN}\\query-lambda.zip" "${TEMP_WIN}\\upload-lambda.zip" 2>/dev/null

# -------------------------------------------
# Step 4: Deploy CloudFormation stack
# -------------------------------------------
echo -e "${Y}[4/7] Deploying CloudFormation stack...${NC}"
echo "  This may take 15-20 minutes (Aurora cluster creation)..."

aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name "$STACK_NAME" \
  --parameter-overrides "Environment=${ENVIRONMENT}" "DocsBucketName=${DOCS_BUCKET}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset

if [[ $? -ne 0 ]]; then
  echo -e "${R}  CloudFormation deployment failed!${NC}"
  echo -e "${R}  Check the AWS Console for error details.${NC}"
  exit 1
fi
echo -e "${G}  Stack deployed successfully${NC}"

# -------------------------------------------
# Step 5: Get stack outputs
# -------------------------------------------
echo -e "${Y}[5/7] Getting stack outputs...${NC}"

API_URL=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiURL'].OutputValue" --output text --region "$REGION")
CLOUDFRONT_URL=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" --output text --region "$REGION")
KB_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" --output text --region "$REGION")

echo -e "${G}  API URL:        ${API_URL}${NC}"
echo -e "${G}  CloudFront URL: ${CLOUDFRONT_URL}${NC}"

# -------------------------------------------
# Step 6: Initialize pgvector extension
# -------------------------------------------
echo -e "${Y}[6/7] Initializing pgvector extension in Aurora...${NC}"

CLUSTER_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "TeamAlpha-vector-cluster" \
  --query "DBClusters[0].DBClusterArn" --output text --region "$REGION")
SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "TeamAlpha-aurora-${ENVIRONMENT}" \
  --query "ARN" --output text --region "$REGION")

aws rds-data execute-statement \
  --resource-arn "$CLUSTER_ARN" \
  --secret-arn "$SECRET_ARN" \
  --database vectordb \
  --sql "CREATE EXTENSION IF NOT EXISTS vector;" \
  --region "$REGION" 2>/dev/null || true

echo -e "${G}  pgvector extension enabled${NC}"

# -------------------------------------------
# Step 7: Deploy frontend
# -------------------------------------------
echo -e "${Y}[7/7] Deploying frontend...${NC}"

TEMP_HTML=$(mktemp /tmp/index-XXXX.html)
sed "s|%%API_URL%%|${API_URL}|g" "$APP_CODE_PATH/frontend/index.html" > "$TEMP_HTML"
aws s3 cp "$TEMP_HTML" "s3://${FRONTEND_BUCKET}/index.html" \
  --content-type "text/html" --region "$REGION"
rm -f "$TEMP_HTML"

echo -e "${G}  Frontend deployed${NC}"

# -------------------------------------------
# Done!
# -------------------------------------------
echo ""
echo -e "${G}============================================${NC}"
echo -e "${G} Deployment Complete!${NC}"
echo -e "${G}============================================${NC}"
echo ""
echo -e "${C} Chat UI:  ${CLOUDFRONT_URL}${NC}"
echo -e "${C} API:      ${API_URL}${NC}"
echo ""
echo -e "${Y} Next steps:${NC}"
echo "   1. Open the Chat UI URL above"
echo "   2. Click 'Upload Docs' and drop a PDF"
echo "   3. Wait ~30s for KB to sync"
echo "   4. Start asking questions!"
echo ""

# Save outputs to file
cat > deployment-outputs.txt <<EOF
Team Alpha Chatbot - Deployment Outputs
========================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Environment: ${ENVIRONMENT}
Region: ${REGION}
Profile: ${AWS_PROFILE}

CloudFront URL: ${CLOUDFRONT_URL}
API URL: ${API_URL}
Docs Bucket: ${DOCS_BUCKET}
Frontend Bucket: ${FRONTEND_BUCKET}
Knowledge Base ID: ${KB_ID}
EOF

echo "  Outputs saved to deployment-outputs.txt"
