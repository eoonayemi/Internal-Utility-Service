# Internal Utility Service — Production Deployment

## Live Application
https://mycapstone-emma.duckdns.org/health

## Project Overview

This project transforms a poorly configured Flask application — running on a
developer's laptop with hardcoded secrets, no tests, no automation, and no
security — into a fully production-grade, containerized web service deployed
on AWS EC2 with HTTPS, automated CI/CD, and zero-downtime deployments.

---

## Architecture Overview

```
Developer → GitHub → GitHub Actions → Docker Hub → AWS EC2
                                                      |
                                              Nginx (HTTPS/SSL)
                                                      |
                                           Flask Container (Docker)
                                                      |
                                         AWS Secrets Manager (runtime)
```

**Full flow:**
1. Developer pushes code to GitHub
2. GitHub Actions triggers automatically
3. Tests and linting run first — failure stops the entire pipeline
4. Docker image is built using a multi-stage build
5. Image is pushed to Docker Hub with 3 tags (latest, semantic version, SHA)
6. GitHub Actions SSHes into EC2 and pulls + runs the new image
7. Nginx receives all external traffic and proxies it to the container
8. Let's Encrypt provides HTTPS — auto-renews every 90 days
9. AWS Secrets Manager stores runtime secrets — never in source code

---

## Repository Structure

```
Internal-Utility-Service/
├── .github/
│   └── workflows/
│       └── deploy.yml        # CI/CD pipeline
├── app.py                    # Flask application
├── config.py                 # App configuration
├── database.py               # Fake database simulation
├── utils.py                  # Utility functions
├── test_app.py               # 8 test cases
├── requirements.txt          # Python dependencies
├── Dockerfile                # Multi-stage Docker build
├── .dockerignore             # Files excluded from Docker build
├── deploy.sh                 # Blue-green deployment script
└── README.md                 # This file
```

---

## Dockerfile Structure

The Dockerfile uses a **two-stage multi-stage build**:

**Stage 1 — Builder:**
- Base image: `python:3.11-slim`
- Installs all dependencies including pytest and flake8
- Copies all source code
- Runs all 8 tests — if any test fails, the build stops here
- The production image is never created from broken code

**Stage 2 — Production:**
- Fresh base image: `python:3.11-slim` (no leftover build tools)
- Creates a non-root system user (`appuser`) for security
- Copies only `app.py`, `config.py`, `database.py`, `utils.py` from Stage 1
- Installs only runtime dependencies: `flask` and `gunicorn`
- Switches to non-root user
- Defines a `HEALTHCHECK` that pings `/health` every 30 seconds
- Starts the app with `gunicorn` (production WSGI server, not flask dev server)

---

## CI/CD Workflow Logic

The pipeline (`.github/workflows/deploy.yml`) has 3 jobs that run in strict sequence:

**Job 1 — Run Tests and Lint:**
- Runs on every push and pull request to main
- Installs dependencies
- Runs `flake8` linting on app.py and test_app.py
- Runs all 8 pytest tests
- If either fails, the pipeline stops — build and deploy are blocked

**Job 2 — Build and Push Docker Image:**
- Only runs if Job 1 passes AND the push is to the main branch
- Logs into Docker Hub using GitHub Secrets
- Builds the multi-stage Docker image
- Pushes 3 tags to Docker Hub simultaneously

**Job 3 — Deploy to EC2:**
- Only runs if Job 2 succeeds
- SSHes into EC2 using the stored SSH key
- Pulls the latest image from Docker Hub
- Stops and removes the old container
- Starts the new container with `--restart always`
- No manual steps required at any point

---

## Tagging Strategy

Three tags are pushed for every successful build:

| Tag | Example | Purpose |
|---|---|---|
| `latest` | `emmy0001/internal-utility-service:latest` | Always points to newest build |
| Semantic version | `emmy0001/internal-utility-service:v1.0.5` | Human-readable, used for rollback |
| Commit SHA | `emmy0001/internal-utility-service:abc1234...` | Exact traceability to source code |

**Why three tags?**
- `latest` is convenient for quick pulls and automated deployments
- `v1.0.X` (where X is the pipeline run number) gives a predictable version
  number for rollback: `docker pull image:v1.0.3` to go back to run 3
- The SHA tag provides forensic traceability — in a production incident,
  you can identify exactly which commit is running on the server

---

## Secret Injection Strategy

Two separate secret systems are used deliberately:

**GitHub Secrets** (pipeline credentials):
- `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` — used to push images
- `EC2_HOST`, `EC2_USERNAME`, `EC2_SSH_KEY` — used to deploy via SSH
- `AWS_REGION` — used for AWS CLI commands
- These exist only during the CI pipeline and are masked in all logs

**AWS Secrets Manager** (runtime application secrets):
- `APP_ENV`, `APP_SECRET_KEY`, `DB_HOST`, `DB_USER`, `DB_PASSWORD`
- EC2 has an IAM role (`EC2SecretsAccessRole`) that grants read access
- The application reads secrets at runtime — never stored in code or image

**Why split between two systems?**
Pipeline secrets and application secrets have completely different lifecycles,
different consumers, and different trust boundaries. The CI pipeline needs
credentials to build and ship the software. The running application needs
credentials to operate. Keeping them separate follows the principle of
least privilege — the pipeline cannot access app secrets and the app
cannot access pipeline credentials.

No secrets appear anywhere in source code, the Dockerfile, commit history,
or Docker image layers.

---

## HTTPS Setup

1. **DuckDNS** provides a free subdomain (`mycapstone-emma.duckdns.org`)
   pointing to the EC2 public IP address
2. **Certbot** with the Nginx plugin obtains a free SSL certificate
   from Let's Encrypt automatically
3. **Nginx** is configured to redirect all HTTP (port 80) traffic to
   HTTPS (port 443)
4. The certificate auto-renews via a systemd timer before it expires
   (Let's Encrypt certificates last 90 days)
5. Certbot automatically updates the Nginx config with strong TLS settings

---

## Deployment Strategy — Blue-Green

The `deploy.sh` script implements zero-downtime blue-green deployment:

1. Pull the latest Docker image from Docker Hub
2. Detect which version is currently live (blue or green)
3. Start the new version on an alternate port (5000 or 5001)
4. Wait 10 seconds for the container to initialize
5. Run a health check against the new container's `/health` endpoint
6. **If health check passes:** update Nginx config to point to new container,
   reload Nginx, stop the old container
7. **If health check fails:** stop the new container immediately,
   old container continues serving traffic — automatic rollback

**Rollback method:**
Run `deploy.sh` again — it detects the current live version and
switches back. Or manually: `docker run` with a specific version tag
(e.g. `v1.0.3`) to pin to a known good release.

---

## Health Checks

- **Docker HEALTHCHECK:** pings `/health` endpoint every 30 seconds,
  3 retries before marking container unhealthy
- **Nginx health endpoint:** `/nginx-health` returns 200 OK
- **Application health endpoint:** `/health` returns `{"status": "UP"}`
- **Container restart policy:** `--restart always` ensures the container
  restarts automatically if it exits unexpectedly

---

## Setup Instructions

```bash
# Clone the repository
git clone https://github.com/eoonayemi/Internal-Utility-Service.git
cd Internal-Utility-Service

# Install dependencies
pip install -r requirements.txt

# Run tests
python -m pytest test_app.py -v

# Run linter
python -m flake8 app.py test_app.py

# Build Docker image locally
docker build -t emmy0001/internal-utility-service:latest .

# Run container locally
docker run -p 5000:5000 emmy0001/internal-utility-service:latest

# Test locally
curl http://localhost:5000/health
```

---

## Reflection Questions

### 1. Why did you structure the Dockerfile the way you did?

The Dockerfile was structured to follow the principle of separation between
the build environment and the runtime environment. The most critical
decision was layer ordering — dependencies are installed before source
code is copied. This takes advantage of Docker's layer caching. When only
source code changes (which happens most often), Docker skips reinstalling
all dependencies and reuses the cached layer, making builds significantly
faster. If the requirements.txt changes, Docker reinstalls everything from
that point. This caching strategy is deliberately exploited by copying
requirements.txt first and the rest of the code second.

The HEALTHCHECK was defined so Docker can monitor the container's health
automatically. Without it, Docker would report a container as "running"
even if the application inside had crashed or was stuck. The health check
pings the /health endpoint every 30 seconds, giving the system continuous
visibility into application status.

Gunicorn was chosen over Flask's built-in development server because
flask run is explicitly not designed for production — it is single-threaded,
has no request queuing, and the debug mode it uses can expose sensitive
information. Gunicorn is a production-grade WSGI server that handles
multiple concurrent requests using worker processes, making it appropriate
for real traffic.

The non-root user was added because running any process as root inside a
container is a serious security risk. If an attacker exploited the
application and gained code execution, running as root would give them
elevated privileges on the host system. Running as a restricted system
user (appuser) limits the blast radius of any security breach significantly.

---

### 2. Why multi-stage build?

A multi-stage Docker build was chosen for three specific reasons: image
size, security, and build integrity.

Image size matters because smaller images download faster, start faster,
and reduce the attack surface. A single-stage build that installs pytest,
flake8, and all development tools would produce an image of several hundred
megabytes. The multi-stage approach produces a production image that contains
only what the application needs to run — Flask and Gunicorn — resulting in
a much smaller and cleaner image.

Security is improved because test tools and build tools are completely absent
from the production image. There is no way for an attacker who compromises
the running container to use pytest, flake8, or any other development utility
because those tools simply do not exist in the final image. The attack surface
is minimized by design.

Build integrity is enforced because tests run in Stage 1 as a mandatory build
step. If any of the 8 tests fail, Docker exits with an error code and Stage 2
never executes — the production image is never created from broken code. This
is stronger than running tests in CI separately because it makes it physically
impossible to build a deployable image from failing code, regardless of whether
the CI pipeline is bypassed. The build process itself becomes a quality gate,
not just the CI pipeline.

---

### 3. Why that tagging strategy?

The three-tag strategy was chosen to serve three different operational needs
simultaneously with a single build.

The `latest` tag exists for convenience. Automated systems, quick tests, and
the deployment script all default to pulling latest. It always points to the
most recently built and tested image, making it the natural default for any
operation that just wants the current version without thinking about version
numbers. However, latest alone is insufficient for production because you
cannot reliably roll back to a specific previous version using it.

The semantic version tag (`v1.0.X` where X is the GitHub Actions run number)
solves the rollback problem. Every pipeline run produces a unique, predictable,
human-readable version number. When an incident occurs and the team needs to
roll back, they can simply run `docker pull image:v1.0.3` and know exactly
what they are getting. The version number is monotonically increasing and
directly corresponds to a pipeline run, making it easy to reason about the
sequence of deployments.

The commit SHA tag provides forensic traceability that neither of the other
tags can offer. In a production incident, you need to answer the question
"exactly what code is running right now?" The SHA tag answers this
definitively — you can look up that exact commit in GitHub and see every
line of code that is deployed. This is invaluable for debugging, security
audits, and compliance requirements. It also protects against the mutable
tag problem — latest and v1.0.X can theoretically be overwritten, but
a SHA is immutable and permanently tied to a specific build.

---

### 4. Why GitHub Secrets and AWS Secrets Manager split?

The decision to use two separate secret management systems reflects the
fundamental difference between secrets that a CI pipeline needs and secrets
that a running application needs. These are different categories of sensitive
data with different consumers, different lifecycles, and different trust
models, and treating them the same way would introduce unnecessary risk.

GitHub Secrets stores the credentials the pipeline needs to do its job: the
Docker Hub token to push images, the EC2 SSH private key to connect and
deploy, and the AWS region configuration. These secrets are consumed by
GitHub Actions workers running in GitHub's infrastructure. They are injected
as environment variables during pipeline execution and masked in all log
output. They have no reason to exist inside the running application on EC2.

AWS Secrets Manager stores the credentials the application needs while it is
running: the database host, username, password, and application secret key.
These are consumed by the Flask application at runtime on the EC2 instance.
The EC2 instance is granted access through an IAM role, which means no
credentials are hardcoded anywhere — the instance proves its identity to
AWS through the IAM role and receives permission to read specific secrets.

This split enforces least privilege: the pipeline cannot read application
runtime secrets, and the application has no knowledge of pipeline credentials.
If either system is compromised, the other remains secure. It also means
that rotating application secrets does not require updating GitHub repository
settings, and rotating pipeline credentials does not require touching the
application or the EC2 instance.

---

### 5. How does your deployment avoid downtime?

The blue-green deployment strategy implemented in `deploy.sh` achieves
zero downtime by ensuring that a healthy version of the application is always
serving traffic before the old version is stopped. Traditional deployments
stop the old version, then start the new version, creating a gap where no
service is available. Blue-green eliminates this gap entirely.

The script works by maintaining two named containers: flask-blue and
flask-green. At any given time, one is live (serving real traffic through
Nginx) and one is inactive. When a deployment is triggered, the script
identifies which container is currently live and starts the new version as
the inactive one on a different port. The new container gets 10 seconds to
initialize, after which a curl request is sent to its /health endpoint.

The health check is the critical gate. Only if the health check returns a
successful response does the script update the Nginx configuration to point
to the new container and reload Nginx. Nginx reloads gracefully — it
finishes serving in-flight requests before switching to the new upstream.
The old container is only stopped after the new one has proven itself healthy
and Nginx is already routing to it. At no point is there a moment where both
containers are down.

If the health check fails, the script immediately stops the new container
and exits with an error code. The live container is completely unaffected —
users experience no disruption. The rollback is instant and automatic,
requiring no human intervention.

---

### 6. How would you scale to multiple EC2 instances?

Scaling to multiple EC2 instances requires moving from a single-server
architecture to a distributed one, which introduces several new components.

The first addition would be an AWS Application Load Balancer (ALB) sitting
in front of all EC2 instances. The ALB distributes incoming HTTPS traffic
across instances using a round-robin or least-connections algorithm. It also
handles SSL termination, removing that responsibility from individual
instances. The DuckDNS domain would point to the ALB's DNS name rather
than a single EC2 IP.

The EC2 instances would be managed by an Auto Scaling Group (ASG) that
automatically adds instances when CPU or request load exceeds a threshold
and removes them when load drops. This means the system scales out during
peak traffic and scales in during quiet periods, keeping costs proportional
to actual usage.

The deployment strategy would need to change from the current blue-green
script to a rolling update approach managed by the ASG. New instances would
launch with the new image version, pass their health checks, and join the
load balancer's target group before old instances are terminated.

The application itself would need to be stateless — which the current Flask
app already is, since it has no session storage or local file dependencies.
Any shared state (user sessions, uploaded files) would need to move to
external services like AWS ElastiCache for sessions and S3 for file storage.
The fake database would need to become a real shared database like AWS RDS
that all instances connect to.

---

### 7. What security risks still exist?

Despite the significant improvements made in this project, several security
risks remain that would need to be addressed before this could be considered
truly production-ready for a sensitive workload.

The most significant risk is that port 22 (SSH) is open to all IP addresses
(0.0.0.0/0) in the EC2 security group. This means any IP address on the
internet can attempt to authenticate via SSH. While the key-based
authentication provides strong protection, best practice is to restrict
SSH access to specific known IP addresses or to use AWS Systems Manager
Session Manager to eliminate the need for SSH entirely.

The application itself still leaks sensitive information. The root endpoint
(/) returns the environment name and database host in the JSON response,
and the /users endpoint returns database credentials as part of the user
objects. These would need to be removed from any real application. Exposing
internal configuration details in API responses gives attackers valuable
information about the system's architecture.

There is no Web Application Firewall (WAF) or rate limiting in place. A
malicious actor could send thousands of requests per second to the server,
potentially causing a denial of service. AWS WAF or Nginx rate limiting
rules would mitigate this.

The SSL certificate and domain both depend on third-party free services
(Let's Encrypt and DuckDNS) that have usage limits and availability
dependencies. For a production service, a registered domain and a paid
certificate would provide better reliability and control.

Secret rotation is also manual — if the database password or application
secret key needs to be changed, it requires manually updating AWS Secrets
Manager and restarting the container. AWS Secrets Manager supports automatic
rotation which would eliminate this manual step.

---

### 8. How would you evolve this into Kubernetes?

Kubernetes (K8s) is the natural evolution of this architecture when the
application needs to run across multiple servers with advanced orchestration,
automatic scaling, and self-healing capabilities that go beyond what a
single EC2 instance with Docker can provide.

The migration would start with containerizing the application exactly as
done in this project — Kubernetes runs Docker containers, so the existing
Dockerfile and Docker Hub image work without modification. The deployment
configuration would move from the current shell script into Kubernetes
manifest files written in YAML.

A Kubernetes Deployment resource would replace the manual `docker run`
commands. The Deployment specifies the desired number of replicas (e.g.,
3 pods running the Flask container), the image to use, resource limits,
and the rolling update strategy. Kubernetes handles rolling updates
natively — it starts new pods, waits for them to pass their readiness
probes, and only then terminates old pods, achieving zero downtime without
a custom deploy.sh script.

A Kubernetes Service resource would replace the Nginx proxy configuration,
providing a stable internal DNS name and load balancing across all pods.
An Ingress resource with cert-manager would replace Certbot, automatically
provisioning and renewing Let's Encrypt certificates for HTTPS.

Kubernetes Secrets would replace GitHub Secrets for runtime configuration,
and integration with AWS Secrets Manager would be handled through the
External Secrets Operator, which automatically syncs AWS secrets into
Kubernetes Secrets. The IAM role would be replaced by IAM Roles for Service
Accounts (IRSA), providing pod-level AWS permissions without credentials.

On AWS, this would be deployed on Amazon EKS (Elastic Kubernetes Service),
which manages the Kubernetes control plane automatically. Helm charts would
package all the manifest files into a deployable unit, making the entire
application reproducible across different environments with a single command.

---

## Trade-offs Made

| Decision | Trade-off |
|---|---|
| DuckDNS free domain | No custom domain, depends on third-party service |
| Single EC2 instance | No high availability, single point of failure |
| Fake database in code | Simple but not realistic for production |
| SSH open to all IPs | Convenient but less secure than IP restriction |
| Manual secret rotation | Simple but requires human intervention |
| t3.micro free tier | Limited CPU/memory for production workloads |

---

## Evidence

- **Green CI/CD pipeline:** GitHub Actions → All 3 jobs passing
- **Failed pipeline:** Test failure blocking build (flake8 error)
- **Docker Hub tags:** latest, v1.0.X, commit SHA visible
- **HTTPS working:** `https://mycapstone-emma.duckdns.org/health`
- **Blue-green deployment:** deploy.sh output showing blue→green switch
- **Container running:** `docker ps` showing flask-green healthy on EC2
- **Nginx config:** `/etc/nginx/sites-available/app` showing proxy setup