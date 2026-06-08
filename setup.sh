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

Run Gateway API exercice
EOD
}

GATEWAY_FULL=false

# get the options
while getopts hs c ; do
    case $c in
	    h) usage ; exit 0 ;;
	    s) GATEWAY_FULL=true ;;
	    \?) usage ; exit 2 ;;
    esac
done
shift `expr $OPTIND - 1`

if [ $# -ne 0 ] ; then
    usage
    exit 2
fi

NSAPP="ingress-app"
NODE1_IP=$(kubectl get nodes --selector="! node-role.kubernetes.io/master" \
    -o=jsonpath='{.items[0].status.addresses[0].address}')

# Run on kubeadm cluster
# see "kubernetes in action" p391
kubectl delete ns -l "demo=gateway-api"
kubectl create namespace "$gateway_ns"
kubectl create namespace "$NSAPP"
kubectl label ns "$gateway_ns" "demo=gateway-api"
kubectl label ns "$NSAPP" "demo=gateway-api"

ink "Install Gateway API CRDs and Envoy Gateway controller"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$gateway_version" \
  --namespace "$gateway_ns" --create-namespace

ink "Wait for Envoy Gateway controller to be up and running"
kubectl wait --timeout=5m -n "$gateway_ns" deployment/envoy-gateway \
  --for=condition=Available

ink "Create GatewayClass exposed via NodePort (no cloud LoadBalancer on this cluster)"
kubectl apply -f $DIR/gatewayclass.yaml

ink "Deploy application"
kubectl create deployment web -n "$NSAPP" --image=gcr.io/google-samples/hello-app:1.0
kubectl expose deployment web -n "$NSAPP" --port=8080
kubectl  wait -n "$NSAPP" --for=condition=available deployment web

TMP_STR="$NODE1_IP hello-world.info"
echo "INFO: Add '$TMP_STR' to /etc/hosts"
sudo sh -c "echo '$TMP_STR' >> /etc/hosts"

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
NODE_PORT=$(kubectl get svc "$EG_SVC" -n "$gateway_ns" \
    -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
HTTPS_NODE_PORT=$(kubectl get svc "$EG_SVC" -n "$gateway_ns" \
    -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

echo "INFO: access the application via the Gateway"
echo "HTTP:  curl hello-world.info:$NODE_PORT"
echo "HTTPS: curl -k https://hello-world.info:$HTTPS_NODE_PORT"
echo ""
curl hello-world.info:$NODE_PORT
echo ""
echo "Testing HTTPS endpoint (ignoring self-signed certificate):"
curl -k https://hello-world.info:$HTTPS_NODE_PORT
