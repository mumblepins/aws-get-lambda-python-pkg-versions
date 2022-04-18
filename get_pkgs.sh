#!/usr/bin/env bash

source .env

if [ -z "$S3_BUCKET" ] || [ -z "$S3_PREFIX" ] || [ -z "$STACK_NAME" ]; then
  echo "Error: .env file is missing variables"
  exit 1
fi

trap cleanup INT
CLEANING_UP=0
function cleanup() {
  if [ $CLEANING_UP -eq 0 ]; then
    CLEANING_UP=1
    _cleanup
  elif [ $CLEANING_UP -eq 1 ]; then
    echo "Error: Stopping cleanup"
    exit 1
  fi
}
function _cleanup() {
  echo "Cleaning up"
  wait_stack
  local temp_file
  temp_file=$(mktemp)
  cat > "$temp_file" << EOF
version = 0.1
[default]
[default.deploy]
[default.deploy.parameters]
stack_name = "$STACK_NAME"
s3_bucket = "$S3_BUCKET"
s3_prefix = "$S3_PREFIX"
region = "REGION"
confirm_changeset = false
capabilities = "$CAPABILITIES"
EOF
  sam delete --no-prompts --region "$REGION" --stack-name "$STACK_NAME" --config-file "$temp_file"
  aws s3 rm --recursive "s3://${S3_BUCKET}/${S3_PREFIX}"
  rm -f "$temp_file"
  exit 0
}

function get_stack_status() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[][].StackStatus' --output text
}

function wait_stack() {
  local list first_wait
  list="UPDATE_COMPLETE CREATE_COMPLETE ROLLBACK_COMPLETE"
  first_wait=0
  while ! [[ $list =~ (^|[[:space:]])$(get_stack_status)($|[[:space:]]) ]]; do
    if [ $first_wait -eq 0 ]; then
      first_wait=1
      stdbuf -o0 echo -n "Waiting for update to complete..."
    else
      stdbuf -o0 echo -n "."
    fi
    sleep 2
  done
  stdbuf -o0 echo "Done"
}
FIRST=1

for po in "${PLATFORMS[@]}"; do
  echo "Override: $po"
  read -r ARCH PY_VERSION <<< "$po"
  if [ $FIRST -eq 1 ]; then
    FIRST=0
    sam deploy --parameter-overrides Architecture="$ARCH" PythonVersion="$PY_VERSION" \
      --region "$REGION" \
      --capabilities "$CAPABILITIES" \
      --s3-bucket "$S3_BUCKET" \
      --s3-prefix "$S3_PREFIX" \
      --stack-name "$STACK_NAME" \
      --no-fail-on-empty-changeset
  else
    aws cloudformation update-stack --stack-name "$STACK_NAME" \
      --use-previous-template \
      --capabilities "$CAPABILITIES" \
      --parameters \
      ParameterKey=Architecture,ParameterValue="$ARCH" \
      ParameterKey=PythonVersion,ParameterValue="$PY_VERSION" > /dev/null 2>&1
    wait_stack
  fi

  arn=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].Outputs[?OutputKey==`LambdaFuncArn`].OutputValue' --output text)
  aws lambda invoke --function-name "$arn" "$REGION-$PY_VERSION-$ARCH.json" > /dev/null 2>&1
done

cleanup
