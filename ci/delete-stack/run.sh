#!/bin/bash
aws cloudformation --region "${REGION}" delete-stack --stack-name "${STACK_NAME}"