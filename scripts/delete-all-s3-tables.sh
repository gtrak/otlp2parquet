#!/bin/bash
# Delete CloudFormation stacks and their associated resources
# Usage: ./delete-all-s3-tables.sh [region] [stack-name]
#
# Arguments:
#   region: AWS region (default: us-west-2)
#   stack-name: Specific CloudFormation stack name to delete (optional)
#               If not provided, lists all stacks and prompts for each
#
# The script will:
#   1. Empty all S3 buckets in the stack
#   2. Delete all S3 Tables (tables and namespaces)
#   3. Delete the CloudFormation stack

set -e

REGION="${1:-us-west-2}"
STACK_NAME="${2:-}"

# Function to empty an S3 bucket (handles versioned buckets)
empty_s3_bucket() {
  local bucket="$1"
  echo "    Emptying bucket: $bucket"

  # First try simple delete
  aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true

  # Check if bucket has versioning - delete all versions
  if aws s3api list-object-versions --bucket "$bucket" --max-keys 1 --query 'Versions[0]' --output text 2>/dev/null | grep -q .; then
    echo "      Deleting versioned objects..."
    uvx --quiet --with boto3 python3 -c "
import boto3
s3 = boto3.resource('s3')
bucket = s3.Bucket('$bucket')
bucket.object_versions.delete()
print('      Deleted all versions')
" 2>&1 || echo "      Warning: Failed to delete versions"
  fi
}

# Function to delete S3 Tables resources for a given table bucket ARN
delete_s3_tables_resources() {
  local bucket_arn="$1"
  echo "    Processing S3 Tables bucket: $bucket_arn"

  # List all namespaces
  local namespaces
  namespaces=$(aws s3tables list-namespaces \
    --region "$REGION" \
    --table-bucket-arn "$bucket_arn" \
    --query 'namespaces[].namespace' \
    --output text 2>/dev/null || true)

  if [ -z "$namespaces" ]; then
    echo "      No namespaces found"
    return
  fi

  # Process each namespace
  echo "$namespaces" | tr '\t' '\n' | while read -r namespace; do
    [ -z "$namespace" ] && continue
    echo "      Namespace: $namespace"

    # List and delete all tables
    local table_names
    table_names=$(aws s3tables list-tables \
      --region "$REGION" \
      --table-bucket-arn "$bucket_arn" \
      --namespace "$namespace" \
      --query 'tables[].name' \
      --output text 2>/dev/null || true)

    if [ -n "$table_names" ]; then
      echo "$table_names" | tr '\t' '\n' | while read -r table_name; do
        [ -z "$table_name" ] && continue
        echo "        Deleting table: $table_name"
        aws s3tables delete-table \
          --region "$REGION" \
          --table-bucket-arn "$bucket_arn" \
          --namespace "$namespace" \
          --name "$table_name" 2>/dev/null || echo "          Failed to delete table"
      done
    fi

    # Delete the namespace
    echo "        Deleting namespace: $namespace"
    aws s3tables delete-namespace \
      --region "$REGION" \
      --table-bucket-arn "$bucket_arn" \
      --namespace "$namespace" 2>/dev/null || echo "          Failed to delete namespace"
  done
}

# Function to delete a single stack and its resources
delete_stack() {
  local stack_name="$1"
  echo ""
  echo "=== Deleting stack: $stack_name ==="

  # Get all S3 bucket resources in the stack
  echo "  Step 1: Finding and emptying S3 buckets..."
  local bucket_resources
  bucket_resources=$(aws cloudformation list-stack-resources \
    --region "$REGION" \
    --stack-name "$stack_name" \
    --query "StackResourceSummaries[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text 2>/dev/null || true)

  if [ -n "$bucket_resources" ]; then
    echo "$bucket_resources" | tr '\t' '\n' | while read -r bucket; do
      [ -z "$bucket" ] && continue
      empty_s3_bucket "$bucket"
    done
  else
    echo "    No S3 buckets found in stack"
  fi

  # Get all S3 Tables table bucket resources
  echo "  Step 2: Finding and cleaning S3 Tables resources..."
  local table_bucket_arns
  table_bucket_arns=$(aws cloudformation list-stack-resources \
    --region "$REGION" \
    --stack-name "$stack_name" \
    --query "StackResourceSummaries[?ResourceType=='AWS::S3Tables::TableBucket'].PhysicalResourceId" \
    --output text 2>/dev/null || true)

  if [ -n "$table_bucket_arns" ]; then
    echo "$table_bucket_arns" | tr '\t' '\n' | while read -r arn; do
      [ -z "$arn" ] && continue
      delete_s3_tables_resources "$arn"
    done
  else
    echo "    No S3 Tables buckets found in stack"
  fi

  # Delete the CloudFormation stack
  echo "  Step 3: Deleting CloudFormation stack..."
  aws cloudformation delete-stack \
    --region "$REGION" \
    --stack-name "$stack_name" 2>&1 || echo "    Failed to initiate stack deletion"

  echo "  Stack deletion initiated for: $stack_name"
}

# Main execution
echo "Region: $REGION"
echo ""

if [ -n "$STACK_NAME" ]; then
  # Delete specific stack
  stack_status=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$stack_status" = "NOT_FOUND" ]; then
    echo "Stack '$STACK_NAME' not found in region $REGION"
    exit 1
  fi

  echo "Found stack: $STACK_NAME (status: $stack_status)"
  delete_stack "$STACK_NAME"
else
  # List all stacks and prompt for each
  echo "Fetching CloudFormation stacks..."
  stack_list=$(aws cloudformation list-stacks \
    --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE CREATE_FAILED UPDATE_COMPLETE UPDATE_FAILED ROLLBACK_COMPLETE DELETE_FAILED \
    --query "StackSummaries[].[StackName,StackStatus]" \
    --output text 2>/dev/null || true)

  if [ -z "$stack_list" ]; then
    echo "No stacks found in region $REGION"
    exit 0
  fi

  echo ""
  echo "Found stacks:"
  echo "$stack_list" | while read -r name status; do
    echo "  - $name ($status)"
  done
  echo ""

  # Process each stack
  echo "$stack_list" | while read -r name status; do
    [ -z "$name" ] && continue

    echo -n "Delete stack '$name' ($status)? [y/N] "
    read -r response </dev/tty

    if [[ "$response" =~ ^[Yy]$ ]]; then
      delete_stack "$name"
    else
      echo "  Skipping: $name"
    fi
  done
fi

echo ""
echo "=== Done ==="
echo ""
echo "Monitor stack deletions with:"
echo "  aws cloudformation list-stacks --region $REGION --stack-status-filter DELETE_IN_PROGRESS DELETE_FAILED --query 'StackSummaries[].[StackName,StackStatus]' --output table"
