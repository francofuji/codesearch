FROM rust:1-trixie AS builder

WORKDIR /app

COPY Cargo.toml Cargo.lock build.rs ./
COPY src ./src
COPY helpers ./helpers

RUN cargo build --release

FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/target/release/codesearch /usr/local/bin/codesearch

ENV CODESEARCH_SERVE_HOST=0.0.0.0
ENV CODESEARCH_SERVE_PORT=39725

EXPOSE 39725

CMD ["codesearch", "serve", "--no-tui"]
