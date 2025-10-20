# Multi-stage build - reduces final image size
FROM eclipse-temurin:17-jdk-jammy AS builder

WORKDIR /workspace
COPY . .

# Build the application using Maven wrapper
RUN ./mvnw clean package -DskipTests -Dcheckstyle.skip=true


# Runtime stage - lighter base image
FROM eclipse-temurin:17-jre-jammy

# Create non-root user for security
RUN useradd -m -u 1000 appuser

# Set working directory
WORKDIR /app

# Copy built JAR from builder stage
COPY --from=builder --chown=appuser:appuser /workspace/target/*.jar app.jar

# Switch to non-root user
USER appuser

# Expose default port (can be overridden via environment variable)
EXPOSE 8080

# Health check for Kubernetes liveness probes
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${SERVER_PORT:-8080}/actuator/health || exit 1

# Run application with environment variables for configuration
ENTRYPOINT ["sh", "-c", "java -jar app.jar \
    --server.port=${SERVER_PORT:-8080} \
    --server.servlet.context-path=${CONTEXT_PATH:-/} \
    --management.endpoints.web.exposure.include=${MANAGEMENT_ENDPOINTS:-health,metrics,prometheus}"]