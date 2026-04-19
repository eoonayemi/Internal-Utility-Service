from flask import Flask, jsonify
from database import get_users
import config

app = Flask(__name__)


@app.route("/")
def home():
    return jsonify({
        "message": "Internal Utility Service Running",
        "environment": config.ENVIRONMENT,
        "db_host": config.DB_HOST
    })


@app.route("/health")
def health():
    return jsonify({"status": "UP"}), 200


@app.route("/users")
def users():
    return jsonify(get_users())


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)