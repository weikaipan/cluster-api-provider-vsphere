#!/bin/bash

# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit  # exits immediately on any unexpected error (does not bypass traps)
set -o nounset  # will error if variables are used without first being defined
set -o pipefail # any non-zero exit code in a piped command causes the pipeline to fail with that code

export PATH=${PWD}/hack/tools/bin:${PATH}
REPO_ROOT=$(git rev-parse --show-toplevel)

# shellcheck source=./hack/ensure-kubectl.sh
source "${REPO_ROOT}/hack/ensure-kubectl.sh"

on_exit() {
  # release IPClaim
  echo "Releasing IP claims"
  kubectl --kubeconfig="${KUBECONFIG}" delete ipclaim "${IPCLAIM_NAME}" || true
  kubectl --kubeconfig="${KUBECONFIG}" delete ipclaim "${WORKLOAD_IPCLAIM_NAME}" || true

  # kill the VPN
  docker kill vpn

  # logout of gcloud
  if [ "${AUTH}" ]; then
    gcloud auth revoke
  fi
}

trap on_exit EXIT

function login() {
  # If GCR_KEY_FILE is set, use that service account to login
  if [ "${GCR_KEY_FILE}" ]; then
    gcloud auth activate-service-account --key-file "${GCR_KEY_FILE}" || fatal "unable to login"
    AUTH=1
  fi
}

AUTH=
E2E_IMAGE_SHA=
GCR_KEY_FILE="${GCR_KEY_FILE:-}"
export VSPHERE_SERVER="${GOVC_URL}"
export VSPHERE_USERNAME="${GOVC_USERNAME}"
export VSPHERE_PASSWORD="${GOVC_PASSWORD}"
export VSPHERE_SSH_AUTHORIZED_KEY="${VM_SSH_PUB_KEY}"
export VSPHERE_SSH_PRIVATE_KEY="/root/ssh/.private-key/private-key"
export E2E_CONF_FILE="${REPO_ROOT}/test/e2e/config/vsphere-ci.yaml"
export ARTIFACTS="${ARTIFACTS:-${REPO_ROOT}/_artifacts}"
export DOCKER_IMAGE_TAR="${ARTIFACTS}/tempContainers/image.tar"
export GC_KIND="false"

# Run the vpn client in container
docker run --rm -d --name vpn -v "${HOME}/.openvpn/:${HOME}/.openvpn/" \
  -w "${HOME}/.openvpn/" --cap-add=NET_ADMIN --net=host --device=/dev/net/tun \
  gcr.io/cluster-api-provider-vsphere/extra/openvpn:latest

# Tail the vpn logs
docker logs vpn

# Sleep to allow vpn container to start running
sleep 30

# Retrieve an IP to be used as the kube-vip IP
KUBECONFIG="/root/ipam-conf/capv-services.conf"
IPCLAIM_NAME="ip-claim-$(date +%s)"
sed "s/IPCLAIM_NAME/${IPCLAIM_NAME}/" "${REPO_ROOT}/hack/ipclaim-template.yaml" | kubectl --kubeconfig=${KUBECONFIG} create -f -

IPADDRESS_NAME=$(kubectl --kubeconfig=${KUBECONFIG} get ipclaim "${IPCLAIM_NAME}" -o=jsonpath='{@.status.address.name}')
CONTROL_PLANE_ENDPOINT_IP=$(kubectl --kubeconfig=${KUBECONFIG} get ipaddresses "${IPADDRESS_NAME}" -o=jsonpath='{@.spec.address}')
export CONTROL_PLANE_ENDPOINT_IP
echo "Acquired Control Plane IP: $CONTROL_PLANE_ENDPOINT_IP"

# Retrieve an IP to be used for the workload cluster in v1a3/v1a4 -> v1b1 upgrade tests
WORKLOAD_IPCLAIM_NAME="workload-ip-claim-$(date +%s)"
sed "s/IPCLAIM_NAME/${WORKLOAD_IPCLAIM_NAME}/" "${REPO_ROOT}/hack/ipclaim-template.yaml" | kubectl --kubeconfig=${KUBECONFIG} create -f -
WORKLOAD_IPADDRESS_NAME=$(kubectl --kubeconfig=${KUBECONFIG} get ipclaim "${WORKLOAD_IPCLAIM_NAME}" -o=jsonpath='{@.status.address.name}')
WORKLOAD_CONTROL_PLANE_ENDPOINT_IP=$(kubectl --kubeconfig=${KUBECONFIG} get ipaddresses "${WORKLOAD_IPADDRESS_NAME}" -o=jsonpath='{@.spec.address}')
export WORKLOAD_CONTROL_PLANE_ENDPOINT_IP
echo "Acquired Workload Cluster Control Plane IP: $WORKLOAD_CONTROL_PLANE_ENDPOINT_IP"

# save the docker image locally
make e2e-image
mkdir -p "$ARTIFACTS"/tempContainers
docker save gcr.io/k8s-staging-cluster-api/capv-manager:e2e -o "$DOCKER_IMAGE_TAR"

# store the image on gcs
login
E2E_IMAGE_SHA=$(docker inspect --format='{{index .Id}}' gcr.io/k8s-staging-cluster-api/capv-manager:e2e)
export E2E_IMAGE_SHA
gsutil cp "$ARTIFACTS"/tempContainers/image.tar gs://capv-ci/"$E2E_IMAGE_SHA"

# Run e2e tests
make e2e
