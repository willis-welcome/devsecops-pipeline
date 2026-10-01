FROM python:3.13-slim

# Patch OS packages and create a non-root user matching the Kubernetes securityContext (UID 1000)
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --uid 1000 --no-create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

# Hash-locked dependencies, prebuilt wheels only (no setup scripts run at build time)
COPY requirements.txt .
RUN pip install --no-cache-dir --only-binary :all: --require-hashes -r requirements.txt

# Copy only the application code, never the whole build context
COPY app.py .

USER 1000

EXPOSE 5000

CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:5000"]
