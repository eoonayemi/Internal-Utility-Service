# =============================================================
# STAGE 1: Builder
# Install all dependencies, run tests to verify code is correct
# =============================================================
FROM python:3.11-slim AS builder

WORKDIR /app

# Copy requirements first — Docker caches this layer
# If requirements.txt hasn't changed, Docker skips reinstalling
COPY requirements.txt .

# Install all dependencies including test tools
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir pytest flake8

# Copy all source code into the builder stage
COPY . .

# Run tests — if ANY test fails, Docker stops here
# The production image is never built from broken code
RUN python -m pytest test_app.py -v

# =============================================================
# STAGE 2: Production
# Clean, minimal image — no test tools, no dev dependencies
# =============================================================
FROM python:3.11-slim AS production

WORKDIR /app

# Create a non-root user and group (security best practice)
# Running as root inside a container is dangerous
RUN addgroup --system appgroup && \
    adduser --system --ingroup appgroup --no-create-home appuser

# Copy only what the production app needs from the builder stage
COPY --from=builder /app/requirements.txt .
COPY --from=builder /app/app.py .
COPY --from=builder /app/config.py .
COPY --from=builder /app/database.py .
COPY --from=builder /app/utils.py .

# Install only runtime dependencies (no pytest, no flake8)
RUN pip install --no-cache-dir flask gunicorn

# Switch to non-root user for security
USER appuser

# Document which port the app listens on
EXPOSE 5000

# Health check — Docker pings /health every 30 seconds
# If it fails 3 times in a row, Docker marks the container as "unhealthy"
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" \
    || exit 1

# Start the app with gunicorn (production WSGI server)
# Never use flask run in production — gunicorn handles multiple requests
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]