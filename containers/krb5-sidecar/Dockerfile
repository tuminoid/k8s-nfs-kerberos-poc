FROM ubuntu:24.04

# Install Kerberos packages including KCM
RUN apt-get update && apt-get install -y \
    krb5-user \
    heimdal-kcm \
    && rm -rf /var/lib/apt/lists/*

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
