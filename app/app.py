# This is a simple Flask web application
# Flask is a lightweight Python web framework
# It receives HTTP requests and returns responses

from flask import Flask, jsonify

# Creates the Flask application instance
# __name__ tells Flask where to find resources relative to this file
app = Flask(__name__)

# This decorator tells Flask to run this function when someone visits /health
# A health endpoint is standard in every production application
# Kubernetes uses it to know if your app is running correctly
@app.route('/health')
def health():
    # Returns a JSON response with status ok
    # jsonify converts a Python dictionary to a proper JSON HTTP response
    return jsonify({"status": "ok"})

# This decorator handles the root URL /
@app.route('/')
def home():
    return jsonify({"message": "DevSecOps Pipeline Running"})

# Only runs the app when this file is executed directly
# Not when it is imported by another file
if __name__ == '__main__':
    # host 0.0.0.0 means accept connections from any IP
    # This is required inside a container so external traffic can reach it
    app.run(host='0.0.0.0', port=5000)