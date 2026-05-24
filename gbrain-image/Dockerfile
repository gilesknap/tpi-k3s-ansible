FROM oven/bun:1 AS builder

RUN bun install -g github:garrytan/gbrain

FROM oven/bun:1-slim

COPY --from=builder /root/.bun/install/global/node_modules /opt/gbrain/node_modules
COPY --from=builder /root/.bun/bin/gbrain /usr/local/bin/gbrain

RUN mkdir -p /home/bun/.gbrain && chown -R bun:bun /home/bun/.gbrain

USER bun
WORKDIR /home/bun

EXPOSE 3131

ENTRYPOINT ["gbrain"]
CMD ["serve", "--http", "--port", "3131", "--bind", "0.0.0.0"]
