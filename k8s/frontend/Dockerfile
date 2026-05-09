FROM alpine
RUN apk update && apk add --no-cache python3 py3-flask py3-pymysql
WORKDIR /app
COPY app.py .
# EXPOSE omitted — documentation-only in Docker, same issue as containerPort in Kubernetes.
# Port is managed at the Service level.
CMD ["python3", "app.py"]
