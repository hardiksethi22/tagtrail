#!/bin/sh
read -r request
id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
case "$1" in
  nonzero)
    printf '{"protocol_version":1,"request_id":"%s","event":"result","payload":{}}\n' "$id"
    exit 7
    ;;
  eof)
    printf '{"protocol_version":1,"request_id":"%s","event":"result","payload":{}}' "$id"
    ;;
  overflow)
    exec /usr/bin/awk 'BEGIN { for(i=0;i<1048577;i++) printf "x"; printf "\n" }'
    ;;
  stall)
    exec /bin/sleep 30
    ;;
  credentials)
    printf '{"protocol_version":1,"request_id":"%s","event":"credential_update","credential_bundle":{"username":"fixture@example.invalid"}}\n' "$id"
    printf '{"protocol_version":1,"request_id":"%s","event":"result","payload":{}}\n' "$id"
    ;;
  *)
    printf '{"protocol_version":1,"request_id":"%s","event":"ready","payload":{}}\n' "$id"
    printf '{"protocol_version":1,"request_id":"%s","event":"result","payload":{}}\n' "$id"
    ;;
esac
