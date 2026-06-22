# Updated to python:3.13-slim to get the latest Python security patches
# python:3.11 has multiple CVEs with fixes available in 3.13
FROM python:3.13-slim

# Run apt-get upgrade to patch any system packages that have fixes available
# This addresses system-level CVEs where patches exist
# --no-install-recommends keeps the image small
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

# Upgrade pip and wheel first to patch their CVEs
# Then install our application dependencies
RUN pip install --no-cache-dir --upgrade pip wheel && \
    pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:5000"]