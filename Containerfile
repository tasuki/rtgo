# Build tools and source stay out of the runtime image.
FROM docker.io/library/erlang:28.2-slim AS katago-build
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl cmake g++ make libeigen3-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl -fsSL https://codeload.github.com/lightvector/KataGo/tar.gz/refs/tags/v1.16.4 -o source.tar.gz \
    && echo '51b1a9b48053b0de910f44abf2cc95160de7b6d43bb22300e0b80ea0b3ed0ca8  source.tar.gz' | sha256sum -c - \
    && tar -xzf source.tar.gz \
    && cmake -S KataGo-1.16.4/cpp -B out \
      -DCMAKE_BUILD_TYPE=Release -DUSE_BACKEND=EIGEN \
      -DNO_GIT_REVISION=1 -DUSE_AVX2=0 \
    && cmake --build out --parallel 2 \
    && strip out/katago
RUN mkdir /bundle \
    && cp out/katago KataGo-1.16.4/LICENSE /bundle/ \
    && curl -fsSL https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b6c96-s175395328-d26788732.txt.gz \
      -o /bundle/kata1-b6c96-s175395328-d26788732.txt.gz \
    && echo '48d6754de3c4754f95bf6a5ca40957a49e5e915aaaeede133a17b9ccf8fa5fcb  /bundle/kata1-b6c96-s175395328-d26788732.txt.gz' | sha256sum -c -

FROM docker.io/library/erlang:28.2-slim AS gleam-tools
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl binutils \
    && rm -rf /var/lib/apt/lists/* \
    && case "$(uname -m)" in x86_64) arch=x86_64 ;; aarch64) arch=aarch64 ;; *) exit 1 ;; esac \
    && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v1.14.0/gleam-v1.14.0-${arch}-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin gleam \
    && curl -fsSL https://github.com/erlang/rebar3/releases/download/3.25.1/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3
FROM gleam-tools AS server-build
WORKDIR /build
COPY shared shared
COPY server server
WORKDIR /build/server
RUN gleam export erlang-shipment \
    && find build/erlang-shipment -type d \( -name src -o -name include \) -prune -exec rm -rf '{}' + \
    && find /usr/local/lib/erlang -type d \( -name src -o -name include -o -name doc \) -prune -exec rm -rf '{}' + \
    && strip /usr/local/lib/erlang/erts-*/bin/beam.smp

FROM gleam-tools AS client-build
WORKDIR /build
COPY shared shared
COPY client client
WORKDIR /build/client
COPY client/config.container.gleam src/config.gleam
RUN gleam run -m lustre/dev build --minify

FROM docker.io/library/debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libncurses6 libstdc++6 libssl3 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=server-build /usr/local/lib/erlang /usr/local/lib/erlang
ENV PATH="/usr/local/lib/erlang/bin:${PATH}"
COPY --from=katago-build /bundle /opt/katago
COPY container/analysis.cfg /opt/katago/analysis.cfg
COPY --from=server-build /build/server/build/erlang-shipment /app
COPY --from=client-build /build/client/dist /app/static
WORKDIR /app
ENV SERVER_PORT=8000
USER 65534:65534
EXPOSE 8000
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
