#!/bin/bash
set -e

RESET_TEXT='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'

### FUNCTIONS ########
function getActiveDeployments() {
    aws deploy list-deployments \
        --application-name "$INPUT_CODEDEPLOY_NAME" \
        --deployment-group-name "$INPUT_CODEDEPLOY_GROUP" \
        --include-only-statuses "Queued" "InProgress" |  jq -r '.deployments';
}

function getSpecificDeployment() {
    aws deploy get-deployment \
        --deployment-id "$1";
}

function pollForSpecificDeployment() {
    deadlockCounter=0;

    while true; do
        RESPONSE=$(getSpecificDeployment "$1")
        FAILED_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Failed')
        IN_PROGRESS_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.InProgress')
        SKIPPED_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Skipped')
        SUCCESS_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Succeeded')
        PENDING_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Pending')
        STATUS=$(echo "$RESPONSE" | jq -r '.deploymentInfo.status')

        echo -e "${ORANGE}Deployment in progress. Sleeping 60 seconds. (Try $((++deadlockCounter)))";
        echo -e "Instance Overview: ${RED}Failed ($FAILED_COUNT), ${BLUE}In-Progress ($IN_PROGRESS_COUNT), ${RESET_TEXT}Skipped ($SKIPPED_COUNT), ${BLUE}Pending ($PENDING_COUNT), ${GREEN}Succeeded ($SUCCESS_COUNT)"
        echo -e "Deployment Status: $STATUS"

        if [ "$FAILED_COUNT" -gt 0 ]; then
            echo -e "${RED}Failed instance detected (Failed count over zero)."
            exit 1;
        fi

        if [ "$STATUS" = "Failed" ]; then
            echo -e "${RED}Failed deployment detected (Failed status)."
            exit 1;
        fi

        if [ "$STATUS" = "Succeeded" ]; then
            break;
        fi

        if [ "$deadlockCounter" -gt "$INPUT_MAX_POLLING_ITERATIONS" ]; then
            echo -e "${RED}Max polling iterations reached (max_polling_iterations)."
            exit 1;
        fi
        sleep 60;
    done;
}

function pollForActiveDeployments() {
    deadlockCounter=0;
    while [ "$(getActiveDeployments)" != "[]" ]; do
        echo -e "${ORANGE}Deployment in progress. Sleeping 60 seconds. (Try $((++deadlockCounter)))";

        if [ "$deadlockCounter" -gt "$INPUT_MAX_POLLING_ITERATIONS" ]; then
            echo -e "${RED}Max polling iterations reached (max_polling_iterations)."
            exit 1;
        fi
        sleep 60s;
    done;
}

function deployRevision() {
    aws deploy create-deployment \
        --application-name "$INPUT_CODEDEPLOY_NAME" \
        --deployment-group-name "$INPUT_CODEDEPLOY_GROUP" \
        --s3-location bucket="$INPUT_S3_BUCKET",bundleType=zip,key="$INPUT_S3_FOLDER"/"$ZIP_FILENAME" | jq -r '.deploymentId'
}


### END OF FUNCTIONS #

# 0) Validation
if [ -z "$INPUT_CODEDEPLOY_NAME" ]; then
    echo "::error::codedeploy_name is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_CODEDEPLOY_GROUP" ]; then
    echo "::error::codedeploy_group is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_AWS_ACCESS_KEY" ]; then
    echo "::error::aws_access_key is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_AWS_SECRET_KEY" ]; then
    echo "::error::aws_secret_key is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_S3_BUCKET" ]; then
    echo "::error::s3_bucket is required and must not be empty."
    exit 1;
fi

echo "::debug::Input variables correctly validated."

# 1) Load our permissions in for aws-cli
export AWS_ACCESS_KEY_ID=$INPUT_AWS_ACCESS_KEY
export AWS_SECRET_ACCESS_KEY=$INPUT_AWS_SECRET_KEY
export AWS_DEFAULT_REGION=$INPUT_AWS_REGION

# 2) Bundle an application revision and upload it to s3

if [ ! -f "$INPUT_DIRECTORY/appspec.yml" ]; then
    echo "::error::appspec.yml was not located at: $INPUT_DIRECTORY"
    exit 1;
fi

echo "::debug::appspec.yml located."

ZIP_FILENAME=$INPUT_CODEDEPLOY_NAME-$INPUT_CODEDEPLOY_GROUP.zip
aws deploy push --application-name "$INPUT_CODEDEPLOY_NAME" --s3-location "s3://$INPUT_S3_BUCKET/$INPUT_S3_FOLDER/$ZIP_FILENAME" --source "$INPUT_DIRECTORY" --ignore-hidden-files --description "$GITHUB_REF - $GITHUB_SHA"

echo "::debug::Revision uploaded."

# 3) Wait until no CodeDeploy deployment is running
pollForActiveDeployments

# 4) Start new deployment
echo -e "${BLUE}Deploying to ${RESET_TEXT}$INPUT_CODEDEPLOY_GROUP."
DEPLOYMENT_ID=$(deployRevision)
echo -e "${GREEN}Deployment created with deployment id: ${RESET_TEXT}$DEPLOYMENT_ID"

# 5) Poll the started deployment
sleep 10
pollForSpecificDeployment "$DEPLOYMENT_ID"
echo -e "${GREEN}Deployed to ${RESET_TEXT}$INPUT_CODEDEPLOY_GROUP!"

exit 0;
