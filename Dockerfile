# Keep Python and Debian versions explicit; update them after testing.
FROM python:3.14.8-slim-trixie

# Avoid runtime bytecode-cache writes to the root-owned application directory.
# Send Python stdout/stderr immediately to container logging.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Reuse the dependency layer when only application code changes.
COPY requirements.txt .
RUN python -m pip install --no-cache-dir -r requirements.txt

COPY helloapp ./helloapp

# A numeric UID/GID runs unprivileged without creating a login account.
USER 65532:65532

EXPOSE 8080

# Exec form lets Gunicorn receive stop signals; "-" sends access logs to stdout.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "helloapp.app:app"]
