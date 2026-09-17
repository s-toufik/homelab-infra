FROM alpine:3.20
RUN apk add --no-cache curl jq
COPY poll-running.sh /poll-running.sh
RUN chmod +x /poll-running.sh
ENTRYPOINT ["/poll-running.sh"]
