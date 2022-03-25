#!/usr/bin/env bash

overrides=(
  "x86_64 python3.7"
  "x86_64 python3.9"
  "x86_64 python3.8"
  "arm64 python3.9"
  "arm64 python3.8"
)
for po in "${overrides[@]}"; do
  echo "Override: $po"
  read -r arch platform <<< "$po"

  sam deploy --parameter-overrides Architecture="$arch" PythonVersion="$platform" --no-fail-on-empty-changeset
  arn=$(aws cloudformation describe-stacks --stack-name get-lambda-python-pkg-versions2 --query 'Stacks[0].Outputs[?OutputKey==`LambdaFuncArn`].OutputValue' --output text)

  aws lambda invoke --function-name "$arn" "$platform-$arch.json"
done
sam delete --no-prompts
aws s3 rm --recursive s3://aws-sam-cli-managed-default-samclisourcebucket-1mrybi0nff7pz/get-lambda-python-pkg-versions2