# Team Alpha Chatbot - Deploy Script
# Run from: c:\MyProjects\AWS\ChatBotInfrastructure\
# Prerequisites:
#   - AWS CLI configured with TeamAlpha-Chatbot-Deployer-Policy attached
#   - Bedrock model access enabled in console (Claude Sonnet + Titan Embeddings v2)

param(
    [string]$Environment = "dev",
    [string]$Region = "us-east-1",
    [string]$StackName = "TeamAlpha-chatbot",
    [string]$AppCodePath = "..\TeamAlphaChatbot"
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Team Alpha Chatbot - Deployment" -ForegroundColor Cyan
Write-Host " Environment: $Environment" -ForegroundColor Cyan
Write-Host " Region: $Region" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------
# Step 1: Get AWS Account ID
# -------------------------------------------
Write-Host "[1/7] Getting AWS account info..." -ForegroundColor Yellow
$AccountId = (aws sts get-caller-identity --query Account --output text --region $Region)
Write-Host "  Account: $AccountId" -ForegroundColor Green

$DocsBucket = "team-alpha-docs-$AccountId"
$FrontendBucket = "team-alpha-frontend-$AccountId"

# -------------------------------------------
# Step 2: Create docs bucket if needed (for Lambda code upload)
# -------------------------------------------
Write-Host "[2/7] Ensuring docs bucket exists..." -ForegroundColor Yellow
$bucketExists = aws s3api head-bucket --bucket $DocsBucket --region $Region 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Creating bucket: $DocsBucket" -ForegroundColor Gray
    aws s3api create-bucket --bucket $DocsBucket --region $Region 2>$null
    if ($Region -ne "us-east-1") {
        aws s3api create-bucket --bucket $DocsBucket --region $Region --create-bucket-configuration LocationConstraint=$Region
    }
}
Write-Host "  Docs bucket ready" -ForegroundColor Green

# -------------------------------------------
# Step 3: Package and upload Lambda functions
# -------------------------------------------
Write-Host "[3/7] Packaging Lambda functions..." -ForegroundColor Yellow

# Query Lambda
$queryDir = "$AppCodePath\backend\query"
$queryZip = "$env:TEMP\query-lambda.zip"
if (Test-Path $queryZip) { Remove-Item $queryZip }
Compress-Archive -Path "$queryDir\lambda_function.py" -DestinationPath $queryZip
aws s3 cp $queryZip "s3://$DocsBucket/lambda/query.zip" --region $Region
Write-Host "  Query Lambda uploaded" -ForegroundColor Green

# Upload Lambda
$uploadDir = "$AppCodePath\backend\upload"
$uploadZip = "$env:TEMP\upload-lambda.zip"
if (Test-Path $uploadZip) { Remove-Item $uploadZip }
Compress-Archive -Path "$uploadDir\lambda_function.py" -DestinationPath $uploadZip
aws s3 cp $uploadZip "s3://$DocsBucket/lambda/upload.zip" --region $Region
Write-Host "  Upload Lambda uploaded" -ForegroundColor Green

# -------------------------------------------
# Step 4: Deploy CloudFormation stack
# -------------------------------------------
Write-Host "[4/7] Deploying CloudFormation stack..." -ForegroundColor Yellow
Write-Host "  This may take 15-20 minutes (Aurora cluster creation)..." -ForegroundColor Gray

aws cloudformation deploy `
    --template-file template.yaml `
    --stack-name $StackName `
    --parameter-overrides "Environment=$Environment" `
    --capabilities CAPABILITY_NAMED_IAM `
    --region $Region `
    --no-fail-on-empty-changeset

if ($LASTEXITCODE -ne 0) {
    Write-Host "  CloudFormation deployment failed!" -ForegroundColor Red
    Write-Host "  Check the AWS Console for error details." -ForegroundColor Red
    exit 1
}
Write-Host "  Stack deployed successfully" -ForegroundColor Green

# -------------------------------------------
# Step 5: Get stack outputs
# -------------------------------------------
Write-Host "[5/7] Getting stack outputs..." -ForegroundColor Yellow

$ApiURL = (aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='ApiURL'].OutputValue" --output text --region $Region)
$CloudFrontURL = (aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" --output text --region $Region)
$KBId = (aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" --output text --region $Region)
$AuroraCluster = (aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='AgentId'].OutputValue" --output text --region $Region)

Write-Host "  API URL: $ApiURL" -ForegroundColor Green
Write-Host "  CloudFront URL: $CloudFrontURL" -ForegroundColor Green

# -------------------------------------------
# Step 6: Initialize pgvector extension
# -------------------------------------------
Write-Host "[6/7] Initializing pgvector extension in Aurora..." -ForegroundColor Yellow

$ClusterArn = (aws rds describe-db-clusters --db-cluster-identifier "TeamAlpha-vector-cluster" --query "DBClusters[0].DBClusterArn" --output text --region $Region)
$SecretArn = (aws secretsmanager describe-secret --secret-id "TeamAlpha-aurora-$Environment" --query "ARN" --output text --region $Region)

aws rds-data execute-statement `
    --resource-arn $ClusterArn `
    --secret-arn $SecretArn `
    --database vectordb `
    --sql "CREATE EXTENSION IF NOT EXISTS vector;" `
    --region $Region 2>$null

Write-Host "  pgvector extension enabled" -ForegroundColor Green

# -------------------------------------------
# Step 7: Deploy frontend
# -------------------------------------------
Write-Host "[7/7] Deploying frontend..." -ForegroundColor Yellow

$frontendDir = "$AppCodePath\frontend"
$tempHtml = "$env:TEMP\index.html"

# Inject API URL into index.html
$htmlContent = Get-Content "$frontendDir\index.html" -Raw
$htmlContent = $htmlContent -replace '%%API_URL%%', $ApiURL
$htmlContent | Out-File -FilePath $tempHtml -Encoding UTF8

aws s3 cp $tempHtml "s3://$FrontendBucket/index.html" --content-type "text/html" --region $Region
Write-Host "  Frontend deployed" -ForegroundColor Green

# -------------------------------------------
# Done!
# -------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Deployment Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host " Chat UI:  $CloudFrontURL" -ForegroundColor Cyan
Write-Host " API:      $ApiURL" -ForegroundColor Cyan
Write-Host ""
Write-Host " Next steps:" -ForegroundColor Yellow
Write-Host "   1. Open the Chat UI URL above" -ForegroundColor White
Write-Host "   2. Click 'Upload Docs' and drop a PDF" -ForegroundColor White
Write-Host "   3. Wait ~30s for KB to sync" -ForegroundColor White
Write-Host "   4. Start asking questions!" -ForegroundColor White
Write-Host ""

# Save outputs to file
$outputFile = "deployment-outputs.txt"
@"
Team Alpha Chatbot - Deployment Outputs
========================================
Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Environment: $Environment
Region: $Region

CloudFront URL: $CloudFrontURL
API URL: $ApiURL
Docs Bucket: $DocsBucket
Frontend Bucket: $FrontendBucket
Knowledge Base ID: $KBId
"@ | Out-File -FilePath $outputFile -Encoding UTF8

Write-Host " Outputs saved to $outputFile" -ForegroundColor Gray
