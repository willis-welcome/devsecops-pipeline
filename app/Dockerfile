# Every Dockerfile starts with a base image
# This is the starting point - a minimal Python 3.11 environment
# slim means it strips out everything not needed to run Python
# smaller image = smaller attack surface = more secure
FROM python:3.11-slim

# Sets the working directory inside the container
# All following commands run from this folder
WORKDIR /app

# Copies requirements.txt into the container first
# We do this separately before copying all code because of Docker layer caching
# If requirements don't change Docker skips reinstalling them on the next build
# This makes builds much faster
COPY requirements.txt .

# Installs all Python dependencies listed in requirements.txt
# --no-cache-dir means don't store the download cache
# Keeps the image smaller - we don't need the cache after installing
RUN pip install --no-cache-dir -r requirements.txt

# Now copies the rest of your application code into the container
COPY . .

# Documents that the container listens on port 5000
# This is informational - it doesn't actually open the port
# The port gets opened when you run the container
EXPOSE 5000

# The command that runs when the container starts
# gunicorn is our production web server
# app:app means find the Flask app object called app inside app.py
# --bind 0.0.0.0:5000 means listen on all interfaces on port 5000
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:5000"]