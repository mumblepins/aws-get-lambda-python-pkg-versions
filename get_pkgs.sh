#!/usr/bin/env bash

source .env

trap cleanup INT
CLEANING_UP=0
CLEANUP_STACK_NAME=
CLEANUP_REGION=
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

  if [[ -n "$CLEANUP_STACK_NAME" ]]; then
    wait_stack "$CLEANUP_STACK_NAME" "$CLEANUP_REGION"
    delete_stack "$CLEANUP_STACK_NAME" "$CLEANUP_REGION"
  fi
  exit 0
}

function delete_stack() {
  echo "Cleaning up stack $1 in $2"
  aws cloudformation delete-stack --stack-name "$1" --region "$2"
  wait_stack "$@"

  CLEANUP_REGION=
  CLEANUP_STACK_NAME=
}

function get_stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$2" --query 'Stacks[][].StackStatus' --output text
}

function wait_stack() {
  local list first_wait
  list="UPDATE_COMPLETE CREATE_COMPLETE ROLLBACK_COMPLETE DELETE_COMPLETE"
  first_wait=0
  while ! [[ $list =~ (^|[[:space:]])$(get_stack_status "$@")($|[[:space:]]) ]]; do
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

function deploy_stacks_to_region() {
  local FIRST=1
  local region=$1
  local stack_id
  for po in "${PLATFORMS[@]}"; do
    echo "In region $r: $po"
    read -r ARCH PY_VERSION <<< "$po"
    if [ $FIRST -eq 1 ]; then
      FIRST=0
      CLEANUP_REGION=$region
      CLEANUP_STACK_NAME=$STACK_NAME
      # shellcheck disable=SC2086
      stack_id=$(aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://template.yaml \
        --parameters \
        ParameterKey=Architecture,ParameterValue="$ARCH" \
        ParameterKey=PythonVersion,ParameterValue="$PY_VERSION" \
        --region "$region" \
        --capabilities $CAPABILITIES \
        --output text \
        --query 'StackId')
      CLEANUP_STACK_NAME=$stack_id
      wait_stack "$stack_id" "$region"
    else
      # shellcheck disable=SC2086
      aws cloudformation update-stack --stack-name "$stack_id" \
        --region "$region" \
        --use-previous-template \
        --capabilities $CAPABILITIES \
        --parameters \
        ParameterKey=Architecture,ParameterValue="$ARCH" \
        ParameterKey=PythonVersion,ParameterValue="$PY_VERSION" >/dev/null
      wait_stack "$stack_id" "$region"
    fi

    arn=$(aws cloudformation describe-stacks --stack-name "$stack_id" --region "$region" --query 'Stacks[0].Outputs[?OutputKey==`LambdaFuncArn`].OutputValue' --output text)
    aws lambda invoke --region $region --function-name "$arn" "$region-$PY_VERSION-$ARCH.json" >/dev/null
  done
  delete_stack "$stack_id" "$region"

}
for r in "${REGIONS[@]}"; do
  deploy_stacks_to_region "$r"
done
