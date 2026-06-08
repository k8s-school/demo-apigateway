#!/bin/bash

# Generate self-signed certificates for HTTPS ingress demo
set -euo pipefail

DOMAIN=${1:-hello-world.info}
CERT_DIR="./certs"

usage() {
  cat << EOD

Usage: $(basename "$0") [domain]

  Generate self-signed certificate for the specified domain

  Arguments:
    domain     Domain name for the certificate (default: hello-world.info)

EOD
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

echo "Generating self-signed certificate for domain: $DOMAIN"

# Create certificate directory
mkdir -p "$CERT_DIR"

# Generate private key
openssl genrsa -out "$CERT_DIR/tls.key" 2048

# Generate certificate signing request
openssl req -new -key "$CERT_DIR/tls.key" -out "$CERT_DIR/tls.csr" -subj "/CN=$DOMAIN/O=Demo Organization/C=US"

# Generate self-signed certificate
openssl x509 -req -days 365 -in "$CERT_DIR/tls.csr" -signkey "$CERT_DIR/tls.key" -out "$CERT_DIR/tls.crt"

echo "Certificate files generated in $CERT_DIR/:"
echo "  - tls.key (private key)"
echo "  - tls.crt (certificate)"
echo "  - tls.csr (certificate signing request)"

# Clean up CSR as it's no longer needed
rm "$CERT_DIR/tls.csr"

echo "Self-signed certificate generated successfully!"