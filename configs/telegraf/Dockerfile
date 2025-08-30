FROM telegraf:1.33-alpine
RUN apk add --no-cache openssh-client jq curl bash
COPY piholeStats.sh /etc/telegraf/piholeStats.sh
RUN chmod +x /etc/telegraf/piholeStats.sh
USER telegraf
