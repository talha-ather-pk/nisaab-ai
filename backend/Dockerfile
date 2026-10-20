# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Nisaab AI — FastAPI backend image
#   docker build -t nisaab-api ./backend
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first for layer caching
COPY requirements.txt .
RUN pip install -r requirements.txt

# Application code
COPY *.py ./

# Run as an unprivileged user
RUN useradd --create-home --uid 10001 nisaab && chown -R nisaab:nisaab /app
USER nisaab

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"

# WEB_CONCURRENCY controls the number of worker processes (default 2).
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port 8000 --workers ${WEB_CONCURRENCY:-2} --proxy-headers --forwarded-allow-ips='*'"]
