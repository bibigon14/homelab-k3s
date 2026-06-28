#!/bin/bash
set -e

CERTS_DIR="$(dirname "$0")"
cd "$CERTS_DIR"

echo "Перевыпускаем сертификат..."
openssl x509 -req -in homelab.local.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out homelab.local.crt \
  -days 397 \
  -extfile homelab.ext

echo "Обновляем секреты в кластере..."
for ns in default monitoring argocd; do
  kubectl create secret tls homelab-tls \
    --cert=homelab.local.crt \
    --key=homelab.local.key \
    --dry-run=client -o yaml | kubectl apply -f - -n $ns
  echo "  ✓ $ns"
done

echo "Перезапускаем Traefik..."
kubectl rollout restart deployment/traefik -n kube-system
kubectl rollout status deployment/traefik -n kube-system

echo "Готово! Срок действия:"
openssl x509 -noout -dates -in homelab.local.crt
