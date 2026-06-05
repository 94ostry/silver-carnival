# silver-carnival
MVN reactor project deployed as docker containers

## Modules
- core-service (Spring Boot REST API)
- processing-service (Spring Boot REST API)
- import-service (Spring Boot REST API)
- task-service (Spring Boot REST API)
- proxy (Nginx reverse proxy)

## Build and test
```bash
mvn clean verify
```

## Build Docker images
```bash
mvn -DskipTests clean package
docker compose build
```

## Run stack
```bash
docker compose up
```

Proxy routes:
- `http://localhost:8080/core/health`
- `http://localhost:8080/processing/health`
- `http://localhost:8080/import/health`
- `http://localhost:8080/task/health`
