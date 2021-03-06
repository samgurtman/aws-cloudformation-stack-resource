#!/bin/bash

retries=10
max_retry_exponent=6
time_between_status_checks=24
time_between_status_checks_fuzz=6

is_stack_completed() {
  status="$(echo "$1" | jq  -c -r '.StackStatus')"
  exit_code=1
  case "$status" in
    CREATE_COMPLETE|UPDATE_COMPLETE|DELETE_COMPLETE) exit_code=0 ;;
  esac
  return "$exit_code"
}

is_stack_recently_deleted() {
  status="$(echo "$1" | jq  -c -r '.StackStatus')"
  exit_code=1
  case "$status" in
    DELETE_COMPLETE) exit_code=0 ;;
  esac
  return "$exit_code"
}

is_stack_not_exist() {
    echo "$1" | grep -Eq "Stack with id $2 does not exist"
    return "$?"
}

is_stack_rolled_back() {
  status="$(echo "$1" | jq -c -r '.StackStatus')"
  exit_code=1
  case "$status" in
    UPDATE_ROLLBACK_COMPLETE) exit_code=0 ;;
  esac
  return "$exit_code"
}

is_stack_create_failed() {
  status="$(echo "$1" | jq -c -r '.StackStatus')"
  exit_code=1
  case "$status" in
    CREATE_FAILED|ROLLBACK_FAILED|ROLLBACK_COMPLETE) exit_code=0 ;;
  esac
  return "$exit_code"
}


is_stack_stuck() {
  status="$(echo "$1" | jq -c -r '.StackStatus')"
  exit_code=1
  case "$status" in
    DELETE_FAILED|UPDATE_ROLLBACK_FAILED) exit_code=0 ;;
  esac
  return "$exit_code"
}

load_stack() {
  stacks=$(aws_with_retry --region "$1" cloudformation describe-stacks --stack-name="$2")
  status="$?"
  if [ "$status" -ne 0 ]; then
    echo "$stacks"
    return "$status"
  fi
  echo "$stacks" | jq '.Stacks[0]'
}

load_change_set() {
  aws_with_retry --region "$1" cloudformation describe-change-set --change-set-name="$2"
}


aws_with_retry(){
    for i in $(seq "$retries"); do
        reason="$(aws "$@" 2>&1)"
        status=$?
        if [ "$status" -eq 0 ] || ! echo "$reason" | grep -q 'Rate exceeded' ; then
             echo "$reason"
             return "$status"
        fi
        exponent=$(( i < max_retry_exponent ? i : max_retry_exponent ))
        timeout=$(bc <<< "scale=4; val=((1.9 + ($RANDOM / 32767 / 5)) ^ $exponent); scale=0; val/1")
        sleep "$timeout"
    done
    echo "$reason"
    return "$status"
}

awaitChangeSetCreated(){
    while true; do
        output="$(load_change_set "$1" "$2")"
        status="$?"

        if [ "$status" -ne 0 ]; then
            echo "$output"
            return "$status"
        else
           state="$(echo "$output" | jq -r '.Status')"
           if [[ "$state" == "CREATE_COMPLETE" ]]; then
             echo "Finished creating change set $2"
             return 0
           elif [[ "$state" == "FAILED" ]]; then
             reason=$(echo "$output" | jq -r '.StatusReason')
             if [[ "$reason" == "The submitted information didn't contain changes."* ]]; then
                echo "No changes to deploy in change set $2"
                return 25
             else
                echo "Failed to create change set due to $reason"
                return 1
             fi
           fi
        fi
        timeout=$(bc <<< "scale=4; val=(($time_between_status_checks - $time_between_status_checks_fuzz) + ($time_between_status_checks_fuzz * ($RANDOM / 32767))); scale=0; val/1")
        sleep "$timeout"
    done
    echo "Timed out waiting for deploy completion!"
    return 255
}

awaitComplete(){
    while true; do
        output="$(load_stack "$1" "$2")"
        status="$?"
        if [ "$status" -ne 0 ]; then
            if is_stack_not_exist "$output" "$2" ; then
                echo "Stack $2 does not exist"
                return 25
            else
                echo "$output"
                return "$status"
           fi
        elif is_stack_rolled_back "$output"; then
            echo "$output"
            return 35
        elif is_stack_create_failed "$output"; then
            echo "$output"
            return 45
        elif is_stack_stuck "$output" ; then
            echo "$output"
            return 55
        elif is_stack_completed "$output"; then
            echo "$output"
            return 0
        fi
        timeout=$(bc <<< "scale=4; val=(($time_between_status_checks - $time_between_status_checks_fuzz) + ($time_between_status_checks_fuzz * ($RANDOM / 32767))); scale=0; val/1")
        sleep "$timeout"
    done
    echo "Timed out waiting for deploy completion!"
    return 255
}

showErrors(){
    events=$(aws_with_retry --region "$1" cloudformation describe-stack-events --stack-name "$2")
    status="$?"
    if [ "$status" -eq 0 ]; then
        echo "$events" | jq --argjson from_before "$3" '.StackEvents[] | select(.ResourceStatus | contains("FAILED")) | select(.Timestamp > ($from_before - 5 | todate))'
    else
        echo "$events"
    fi
    return "$status"
}

