# Simple demo for Kubernetes Gateway API (Envoy Gateway)

## Pre-requisites

- An up and running Kubernetes cluster
- OpenSSL for certificate generation

## Launch the demo

```bash
git clone https://github.com/k8s-school/demo-apigateway
cd demo-apigateway
./setup.sh
```

## From Ingress to Gateway API

This demo used to be built on the nginx Ingress Controller; it now showcases the
[Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/), the API that is
gradually superseding `Ingress`. The concepts map onto what `Ingress` users
already know:

- `GatewayClass` selects the controller implementation (here
  [Envoy Gateway](https://gateway.envoyproxy.io/)) — the equivalent of an
  `IngressClass`.
- `Gateway` configures the listeners (ports, hostnames, TLS termination) and is
  exposed to the cluster — combining what `Ingress`'s `spec.tls` and the
  controller's Service exposure used to do.
- `HTTPRoute` defines the host/path routing rules and backend references — the
  equivalent of `Ingress`'s `spec.rules`. Note that the backend is referenced via
  `backendRefs[].port` rather than `backend.service.port.number`.

`gatewayclass.yaml` contains the platform-level resources (`GatewayClass` and an
`EnvoyProxy` configuration exposing the Gateway via NodePort, since this demo runs
on a bare cluster with no cloud LoadBalancer). `example-httproute.yaml` contains
the application-level resources (`Gateway` and `HTTPRoute`) — this is the file
that plays the role of the former `example-ingress.yaml`.

## HTTPS Support

This demo includes automatic generation of self-signed certificates for HTTPS.
The setup script:

1. Generates self-signed certificates using `generate-certs.sh`
2. Creates a Kubernetes TLS secret with the certificates
3. Configures the Gateway's HTTPS listener to terminate TLS using that secret

### Manual certificate generation

You can also generate certificates manually:

```bash
./generate-certs.sh [domain-name]
```

Default domain is `hello-world.info`. Certificates are stored in `./certs/` directory.

### Accessing the application

After running `./setup.sh -s`, you can access the application via the Gateway:

- **HTTP**: `curl hello-world.info:<node-port>`
- **HTTPS**: `curl -k https://hello-world.info:<https-node-port>`

The `-k` flag ignores the self-signed certificate warnings.
