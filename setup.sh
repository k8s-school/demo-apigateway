#!/bin/bash

# See https://gateway.envoyproxy.io/docs/tasks/quickstart/
# and https://gateway-api.sigs.k8s.io/
set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)

. $DIR/conf.sh

usage() {
  cat << EOD

Usage: `basename $0` [options]

  Available options:
    -h         this message
    -s         run exercice and solution
    -a         also run the canary and A/B testing solution (implies -s)

Run Gateway API exercice
EOD
}

GATEWAY_FULL=false
AB_TESTING=false

# get the options
while getopts hsa c ; do
    case $c in
	    h) usage ; exit 0 ;;
	    s) GATEWAY_FULL=true ;;
	    a) GATEWAY_FULL=true ; AB_TESTING=true ;;
	    \?) usage ; exit 2 ;;
    esac
done
shift `expr $OPTIND - 1`

if [ $# -ne 0 ] ; then
    usage
    exit 2
fi

# Per-trainee application namespace: the cluster may be shared
ID="${ID:-$(id -un)}"
NSAPP="gateway-$ID"
NODE1_IP=$(kubectl get nodes --selector="! node-role.kubernetes.io/master" \
    -o=jsonpath='{.items[0].status.addresses[0].address}')

# Run on kubeadm cluster
# see "kubernetes in action" p391
# Only the namespace of this trainee is reset: the Envoy Gateway controller
# namespace is shared, never delete it
kubectl delete ns -l "demo=gateway-api-$ID"
kubectl create namespace "$NSAPP"
kubectl label ns "$NSAPP" "demo=gateway-api-$ID"

# The controller is shared by all the trainees of the cluster: install it only
# once, two concurrent 'helm upgrade --install' fail with "cannot re-use a name
# that is still in use"
if kubectl get deployment -n "$gateway_ns" envoy-gateway >/dev/null 2>&1; then
  ink -y "Envoy Gateway controller already installed, skipping"
else
  ink "Install Gateway API CRDs and Envoy Gateway controller"
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$gateway_version" \
    --namespace "$gateway_ns" --create-namespace
fi

ink "Wait for Envoy Gateway controller to be up and running"
kubectl wait --timeout=5m -n "$gateway_ns" deployment/envoy-gateway \
  --for=condition=Available

ink "Create GatewayClass exposed via NodePort (no cloud LoadBalancer on this cluster)"
kubectl apply -f $DIR/gatewayclass.yaml

ink "Deploy application"
kubectl create deployment web -n "$NSAPP" --image=gcr.io/google-samples/hello-app:1.0
kubectl expose deployment web -n "$NSAPP" --port=8080
kubectl  wait -n "$NSAPP" --for=condition=available deployment web

echo "INFO: to access the application by name, add '$NODE1_IP hello-world.info' to /etc/hosts"

if [ "$GATEWAY_FULL" = false ]
then
    exit 0
fi

ink "Generate self-signed certificates for HTTPS"
$DIR/generate-certs.sh hello-world.info

ink "Create TLS secret from generated certificates"
kubectl create secret tls hello-world-tls -n "$NSAPP" \
    --key $DIR/certs/tls.key \
    --cert $DIR/certs/tls.crt

ink "Create Gateway and HTTPRoute with TLS (replaces the former Ingress resource)"
kubectl apply -n "$NSAPP" -f $DIR/example-httproute.yaml
kubectl get -n "$NSAPP" gateway,httproute

ink "Wait for the Gateway to be programmed/accepted"
kubectl wait -n "$NSAPP" --for=condition=Programmed gateway/example-gateway --timeout=2m

ink "Access the application"
EG_SVC=$(kubectl get svc -n "$gateway_ns" \
    -l "gateway.envoyproxy.io/owning-gateway-namespace=$NSAPP,gateway.envoyproxy.io/owning-gateway-name=example-gateway" \
    -o jsonpath="{.items[0].metadata.name}")
# Match by .port (the container port), not .name: it directly mirrors the
# port numbers declared on the Gateway's listeners (80/443) in
# example-httproute.yaml, which we control - unlike .name, whose convention
# is an Envoy Gateway implementation detail that can vary across versions.
NODE_PORT=$(kubectl get svc "$EG_SVC" -n "$gateway_ns" \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
HTTPS_NODE_PORT=$(kubectl get svc "$EG_SVC" -n "$gateway_ns" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')

echo "INFO: access the application via the Gateway"
echo "HTTP:  curl hello-world.info:$NODE_PORT"
echo "HTTPS: curl -k https://hello-world.info:$HTTPS_NODE_PORT"
echo ""
# --resolve avoids depending on /etc/hosts
CURL="curl -sS --fail --resolve hello-world.info:$NODE_PORT:$NODE1_IP"
$CURL hello-world.info:$NODE_PORT
echo ""
echo "Testing HTTPS endpoint (ignoring self-signed certificate):"
curl -sS --fail -k --resolve "hello-world.info:$HTTPS_NODE_PORT:$NODE1_IP" https://hello-world.info:$HTTPS_NODE_PORT

if [ "$AB_TESTING" = false ]
then
    exit 0
fi

# Count the answers of each version over 100 requests
# $@: extra curl options
count_versions() {
    for i in $(seq 100); do
        $CURL "$@" hello-world.info:$NODE_PORT | grep "^Version:"
    done | sort | uniq -c
}

ink "Deploy version 2 of the application"
kubectl create deployment web-v2 -n "$NSAPP" --image=gcr.io/google-samples/hello-app:2.0
kubectl expose deployment web-v2 -n "$NSAPP" --port=8080
kubectl wait -n "$NSAPP" --for=condition=available deployment web-v2

ink "Canary release: send 10% of the traffic to version 2"
kubectl apply -n "$NSAPP" -f $DIR/httproute-canary.yaml
# Wait for the new HTTPRoute to be programmed in Envoy
timeout 60 sh -c "until $CURL hello-world.info:$NODE_PORT | grep -q 'Version: 2.0.0'; do sleep 1; done"
count_versions
V2=$(count_versions | awk '/2.0.0/ {print $1}')
if [ "${V2:-0}" -lt 2 ] || [ "${V2:-0}" -gt 25 ]; then
    ink -r "Expected about 10% of the requests on version 2, got ${V2:-0}%"
    exit 1
fi

ink "A/B testing: route on the HTTP header 'x-version: v2'"
kubectl apply -n "$NSAPP" -f $DIR/httproute-ab.yaml
timeout 60 sh -c "until [ \"\$($CURL hello-world.info:$NODE_PORT | grep Version:)\" = 'Version: 1.0.0' ] && $CURL -H 'x-version: v2' hello-world.info:$NODE_PORT | grep -q 'Version: 2.0.0'; do sleep 1; done"
count_versions
count_versions -H "x-version: v2"
[ "$(count_versions | awk '{print $3}')" = "1.0.0" ] || { ink -r "Requests without header must all go to version 1"; exit 1; }
[ "$(count_versions -H 'x-version: v2' | awk '{print $3}')" = "2.0.0" ] || { ink -r "Requests with header must all go to version 2"; exit 1; }
ink "Canary and A/B testing: success"
