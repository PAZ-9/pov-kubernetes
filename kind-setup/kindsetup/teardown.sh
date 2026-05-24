#!/usr/bin/env bash

kind delete clusters sgdc-cluster
kubectl config delete-context sgdc

kind delete clusters jpdc-cluster
kubectl config delete-context jpdc

kind delete clusters audc-cluster
kubectl config delete-context audc



