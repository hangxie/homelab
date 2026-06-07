#!/bin/bash

set -euo pipefail

# scylla is excluded intentionally
terraform -chdir=terraform init -no-color \
    && terraform -chdir=terraform destroy --auto-approve -no-color \
    && terraform -chdir=terraform apply --auto-approve -no-color -parallelism=5 \
    && rm -rf ~/.ansible/tmp/* \
    && time ansible-playbook -i ansible/inventory.ini ansible/bootstrap-k8s.yml
