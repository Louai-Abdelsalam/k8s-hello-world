#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

echo "=== Phase 1: Cluster and Namespace ==="
minikube start
minikube addons enable ingress
minikube kubectl -- apply --filename k8s/namespace.yaml
minikube kubectl -- get namespace guestbook

sleep 15

echo "=== Phase 2: StorageClass ==="
minikube kubectl -- apply --filename k8s/storage/storageclass.yaml
minikube kubectl -- get storageclass guestbook-storage

sleep 15

echo "=== Phase 3: Storage ==="
minikube kubectl -- apply --filename k8s/storage/pv.yaml --filename k8s/storage/pvc.yaml
minikube kubectl -- wait pvc/guestbook-mariadb-pvc --namespace guestbook --for=jsonpath='{.status.phase}'=Bound --timeout=60s
minikube kubectl -- get pv guestbook-mariadb-pv
minikube kubectl -- get pvc guestbook-mariadb-pvc --namespace guestbook

sleep 15

echo "=== Phase 4: Configuration ==="
minikube kubectl -- apply --filename k8s/config/configmap.yaml --filename k8s/config/configmap-seed.yaml --filename k8s/config/secret.yaml
minikube kubectl -- describe configmap guestbook-config --namespace guestbook
minikube kubectl -- describe configmap guestbook-seed-sql --namespace guestbook
minikube kubectl -- describe secret guestbook-secret --namespace guestbook

sleep 15

echo "=== Phase 5: Database ==="
minikube kubectl -- apply --filename k8s/database/statefulset.yaml --filename k8s/database/service.yaml
minikube kubectl -- rollout status statefulset/guestbook-mariadb --namespace guestbook --timeout=120s
minikube kubectl -- exec guestbook-mariadb-0 --namespace guestbook -- mariadb -u root -prootpass123 -e "SELECT 1"

sleep 15

echo "=== Phase 6: Seed Job ==="
minikube kubectl -- apply --filename k8s/jobs/seed-job.yaml
minikube kubectl -- wait job/guestbook-seed --namespace guestbook --for=condition=complete --timeout=120s
minikube kubectl -- exec guestbook-mariadb-0 --namespace guestbook -- mariadb -u root -prootpass123 guestbook -e "DESCRIBE entries"
minikube kubectl -- exec guestbook-mariadb-0 --namespace guestbook -- mariadb -u root -prootpass123 guestbook -e "SELECT * FROM entries"
minikube kubectl -- exec guestbook-mariadb-0 --namespace guestbook -- mariadb -u guestbook_user -pguestbook_pass guestbook -e "SELECT 1"

sleep 15

echo "=== Phase 7: Frontend ==="
docker build --tag guestbook-frontend:1.0 --network=host --file k8s/frontend/Dockerfile k8s/frontend/
minikube image load guestbook-frontend:1.0
minikube kubectl -- apply --filename k8s/frontend/deployment.yaml --filename k8s/frontend/service.yaml
minikube kubectl -- rollout status deployment/guestbook-frontend --namespace guestbook --timeout=120s
FRONTEND_POD=$(minikube kubectl -- get pods --namespace guestbook --selector=app=frontend --output=jsonpath='{.items[0].metadata.name}')
minikube kubectl -- port-forward "$FRONTEND_POD" 5000:5000 --namespace guestbook &
PF_PID=$!
sleep 5
curl http://localhost:5000/messages
curl --request POST http://localhost:5000/messages --header "Content-Type: application/json" --data '{"message":"Deployment verification entry"}'
curl http://localhost:5000/messages
kill $PF_PID 2>/dev/null || true

sleep 15

echo "=== Phase 8: NetworkPolicy ==="
minikube kubectl -- apply --filename k8s/database/networkpolicy.yaml
FRONTEND_POD=$(minikube kubectl -- get pods --namespace guestbook --selector=app=frontend --output=jsonpath='{.items[0].metadata.name}')
minikube kubectl -- port-forward "$FRONTEND_POD" 5000:5000 --namespace guestbook &
PF_PID=$!
sleep 5
curl http://localhost:5000/messages
kill $PF_PID 2>/dev/null || true
echo "Verifying denied traffic (expected: connection error or timeout — NetworkPolicy blocks pods not matching frontend/seed/cleanup)..."
minikube kubectl -- run test-pod \
  --rm \
  --restart=Never \
  --attach \
  --image=mariadb:11.8 \
  --namespace guestbook \
  -- mariadb -h guestbook-mariadb -u guestbook_user -pguestbook_pass guestbook --connect-timeout=5 -e "SELECT 1" || true

sleep 15

echo "=== Phase 9: CronJob ==="
minikube kubectl -- apply --filename k8s/jobs/cleanup-cronjob.yaml
echo "Waiting 70s for first CronJob run..."
sleep 70
minikube kubectl -- get cronjobs --namespace guestbook
minikube kubectl -- get jobs --namespace guestbook --selector=app=cleanup

echo "=== Phase 10: Ingress ==="
minikube kubectl -- apply --filename k8s/frontend/ingress.yaml
echo ""
echo "Deployment complete. Access the guestbook at: http://$(minikube ip)/"
