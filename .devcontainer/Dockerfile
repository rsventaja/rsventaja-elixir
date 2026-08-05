# Keep in sync with .tool-versions and production Dockerfile.
FROM hexpm/elixir:1.16.3-erlang-26.2.5.21-alpine-3.20.9

# Install additional build dependencies needed for native compilation
# Also install Tesseract OCR, Portuguese language pack, and poppler-utils for PDF to image conversion
RUN apk add --no-cache \
    gcc \
    g++ \
    make \
    libc-dev \
    tesseract-ocr \
    tesseract-ocr-data-por \
    poppler-utils \
    git \
    inotify-tools \
    && rm -rf /var/cache/apk/*

WORKDIR /app

# Install Hex and Rebar globally
RUN mix do local.hex --force, local.rebar --force

# Set MIX_ENV to dev for development
ENV MIX_ENV=dev

# Keep container running for dev container usage
CMD ["sleep", "infinity"]




