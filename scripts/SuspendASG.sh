#!/bin/bash

export PATH="$PATH:/usr/bin:/usr/local/bin"

# If true, all messages will be printed. If false, only fatal errors are printed.

DEBUG=true

# If true, all commands will have a initial jitter - use this if deploying to significant number of instances only

INITIAL_JITTER=false

#
# Performs CLI command and provides expotential backoff with Jitter between any failed CLI commands
# FullJitter algorithm taken from: https://www.awsarchitectureblog.com/2015/03/backoff.html
# Optional pre-jitter can be enabled  via GLOBAL var INITIAL_JITTER (set to "true" to enable)
#

exec_with_fulljitter_retry() {
    local MAX_RETRIES=${EXPBACKOFF_MAX_RETRIES:-8} # Max number of retries
    local BASE=${EXPBACKOFF_BASE:-2} # Base value for backoff calculation
    local MAX=${EXPBACKOFF_MAX:-120} # Max value for backoff calculation
    local FAILURES=0
    local RESP

    # Perform initial jitter sleep if enabled
    if [ "$INITIAL_JITTER" = "true" ]; then
      local SECONDS=$(( $RANDOM % ( ($BASE * 2) ** 2 ) ))
      sleep $SECONDS
    fi

    # Execute Provided Command
    RESP=$(eval $@)
    until [ $? -eq 0 ]; do
        FAILURES=$(( $FAILURES + 1 ))
        if (( $FAILURES > $MAX_RETRIES )); then
            echo "$@" >&2
            echo " * Failed, max retries exceeded" >&2
            return 1
        else
            local SECONDS=$(( $RANDOM % ( ($BASE * 2) ** $FAILURES ) ))
            if (( $SECONDS > $MAX )); then
                SECONDS=$MAX
            fi

            echo "$@" >&2
            echo " * $FAILURES failure(s), retrying in $SECONDS second(s)" >&2
            sleep $SECONDS

            # Re-Execute provided command
            RESP=$(eval $@)
        fi
    done

    # Echo out CLI response which is captured by calling function
    echo $RESP
    return 0
}

# Usage: get_instance_region
#
#   Writes to STDOUT the AWS region as known by the local instance.
get_instance_region() {
    if [ -z "$AWS_REGION" ]; then
        AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
            | grep -i region \
            | awk -F\" '{print $4}')
    fi

    echo $AWS_REGION
}

AWS_CLI="exec_with_fulljitter_retry aws --region $(get_instance_region)"

# Usage: suspend_processes
#
#   Suspend processes known to cause problems during deployments.
#   The API call is idempotent so it doesn't matter if any were previously suspended.

suspend_processes() {
  local -a processes=(AZRebalance AlarmNotification ScheduledActions ReplaceUnhealthy Launch Terminate)
  msg "Autoscaling Group to suspend process under deployment group name:  $DEPLOYMENT_GROUP_NAME "

  local asg_name=$($AWS_CLI deploy get-deployment-group --application-name $APPLICATION_NAME --deployment-group-name $DEPLOYMENT_GROUP_NAME --output text --query deploymentGroupInfo.autoScalingGroups[0].name)
  #local asg_name=$($AWS_CLI deploy get-deployment --deployment-id $DEPLOYMENT_ID --output text --query deploymentInfo.targetInstances.autoScalingGroups[0])
  msg "Suspending ${processes[*]} processes over autoScalingGroup $asg_name"
  $AWS_CLI autoscaling suspend-processes \
    --auto-scaling-group-name \"${asg_name}\" \
    --scaling-processes ${processes[@]}
  if [ $? != 0 ]; then
    error_exit "Failed to suspend ${processes[*]} processes for ASG ${asg_name}. Aborting as this may cause issues."
  fi
}

# Usage: msg <message>
#
#   Writes <message> to STDERR only if $DEBUG is true, otherwise has no effect.
msg() {
    local message=$1
    $DEBUG && echo $message 1>&2
}

# Usage: error_exit <message>
#
#   Writes <message> to STDERR as a "fatal" and immediately exits the currently running script.
error_exit() {
    local message=$1

    echo "[FATAL] $message" 1>&2
    exit 1
}

# Usage: finish_msg
#
#   Prints some finishing statistics
finish_msg() {
  msg "Finished $(basename $0) at $(/bin/date "+%F %T")"

  end_sec=$(/bin/date +%s.%N)
  elapsed_seconds=$(echo "$end_sec" "$start_sec" | awk '{ print $1 - $2 }')

  msg "Elapsed time: $elapsed_seconds"
}

suspend_processes
finish_msg
