FROM alpine:3.19

# Install all required packages including Tor + jq (needed by
# panel-bootstrap.sh to build/merge the Xray config JSON)
RUN apk add --no-cache \
    curl \
    bash \
    ca-certificates \
    socat \
    tzdata \
    sqlite \
    nginx \
    gettext \
    tor \
    jq \
    && ln -sf /usr/share/zoneinfo/Asia/Tehran /etc/localtime

# Download and install 3x-ui
RUN curl -L https://github.com/mhsanaei/3x-ui/releases/download/v3.5.0/x-ui-linux-amd64.tar.gz -o /tmp/x-ui.tar.gz \
    && tar -xzf /tmp/x-ui.tar.gz -C /usr/local/ \
    && rm /tmp/x-ui.tar.gz \
    && chmod +x /usr/local/x-ui/x-ui

# Create necessary directories
# (per-country Tor instance dirs are created at runtime by
# start.sh, not here, since the country list lives in start.sh)
RUN mkdir -p /etc/x-ui /var/log/x-ui /var/log/tor

# Copy configuration files
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY start.sh /start.sh
COPY panel-bootstrap.sh /panel-bootstrap.sh
RUN chmod +x /start.sh /panel-bootstrap.sh

# Railway injects PORT via environment variable and routes its public
# domain to it automatically - no EXPOSE needed for that part.
#
# The Tor SOCKS ports (9050-9059) are documented here only so it's
# clear which ports exist if you choose to expose one publicly via
# Railway's TCP Proxy feature (Settings -> Networking -> TCP Proxy).
# EXPOSE has no effect on Railway routing by itself.
EXPOSE 9050 9051 9052 9053 9054 9055 9056 9057 9058 9059

CMD ["/start.sh"]