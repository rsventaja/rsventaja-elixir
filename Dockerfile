# Keep in sync with .tool-versions (Elixir 1.16.3 / OTP 26.2.5.21).
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
    && rm -rf /var/cache/apk/*


WORKDIR /app

# Install Hex and Rebar
RUN mix do local.hex --force, local.rebar --force

# Copy dependency files
COPY mix.exs .
COPY mix.lock .

# Set build argument for MIX_ENV
ARG MIX_ENV=prod
ENV MIX_ENV=${MIX_ENV}

# Fetch and compile dependencies
RUN mix deps.get --only ${MIX_ENV} && \
    mix deps.compile

# Copy application code
COPY . .

# Compile the application
RUN mix compile

# Build assets (if needed)
RUN mix assets.deploy || true

# Expose port
EXPOSE 4000

# Use exec form for better signal handling
CMD ["mix", "phx.server"]