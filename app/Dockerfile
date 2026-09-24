FROM python:3.13-slim

# Patch OS packages that have fixes available
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Non-root user matching the Kubernetes securityContext (UID 1000)
RUN useradd --uid 1000 --no-create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

# Dependencies first so this layer is cached when only app code changes
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip wheel && \
    pip install --no-cache-dir -r requirements.txt

COPY . .

USER 1000

EXPOSE 5000

CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:5000"]
