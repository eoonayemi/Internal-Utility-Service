#!/bin/bash
IMAGE="emmy0001/internal-utility-service:latest"

echo "Starting Blue-Green Deployment..."
docker pull $IMAGE

if docker ps --format '{{.Names}}' | grep -q "flask-blue"; then
    LIVE="flask-blue"
    NEXT="flask-green"
    NEXT_PORT="5001"
else
    LIVE="flask-green"
    NEXT="flask-blue"
    NEXT_PORT="5000"
fi

echo "Currently live: $LIVE — Deploying: $NEXT on port $NEXT_PORT"

docker stop $NEXT 2>/dev/null || true
docker rm $NEXT 2>/dev/null || true

docker run -d \
    --name $NEXT \
    --restart always \
    -p $NEXT_PORT:5000 \
    $IMAGE

echo "Waiting for new container to be ready..."
sleep 10

if curl -sf http://localhost:$NEXT_PORT/health > /dev/null; then
    echo "Health check PASSED — switching traffic..."
    sudo sed -i "s|proxy_pass http://localhost:[0-9]*;|proxy_pass http://localhost:$NEXT_PORT;|" \
        /etc/nginx/sites-available/app
    sudo nginx -t && sudo systemctl reload nginx
    docker stop $LIVE || true
    docker rm $LIVE || true
    echo "Deployment SUCCESSFUL — now serving: $NEXT"
else
    echo "Health check FAILED — rolling back..."
    docker stop $NEXT || true
    docker rm $NEXT || true
    echo "ROLLBACK COMPLETE — still running: $LIVE"
    exit 1
fi