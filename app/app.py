from flask import Flask, jsonify

app = Flask(__name__)


# Applied to every response, including error pages (remediates OWASP ZAP findings)
@app.after_request
def set_security_headers(response):
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "default-src 'self'; frame-ancestors 'none'; form-action 'self'"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    return response


# Used by Kubernetes probes and the pipeline readiness check
@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/")
def home():
    return jsonify({"message": "DevSecOps Pipeline Running"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
