#!/bin/bash

cd $(dirname "$0") || (echo "Can't cd to script directory" && exit 1)

if [ -z "$1" ]; then
    echo "No project found, exiting..."
    exit 1
fi

if [ ! -d $1 ]; then
    echo "Terraform project $1 not found!"
    exit 1
fi

echo "Starting terraform project: '$1'"

if [ ! -f .env ]; then
    echo ".env is not found! Are you sure you want to continue? CTRL + C to cancel, will continue in 5 seconds"
    sleep 5
fi

set -a
source .env
set +a

echo "TF_VAR_* Environment Variables:"
export | grep "TF_VAR"
sleep 1

echo "Initializing project $1 and planning..."
cd $1 && terraform init && terraform plan
echo "This is the plan for $1, continue?"

# via https://stackoverflow.com/a/29436423
function yes_or_no {
    while true; do
        read -p "$* [y/n]: " yn
        case $yn in
            [Yy]*) return 0  ;;  
            [Nn]*) echo "Aborted" ; return  1 ;;
        esac
    done
}

yes_or_no "Continue with 'terraform apply on $1?" && terraform apply

yes_or_no "Destroy the 'terraform apply' project just applied on $1?" && terraform destroy