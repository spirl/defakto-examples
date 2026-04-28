FROM alpine:3.19

RUN apk add --no-cache curl jq

COPY --from=fullstorydev/grpcurl:latest /bin/grpcurl /bin/grpcurl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]