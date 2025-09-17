FROM ubuntu:24.04

# Install all required packages for NFS with Kerberos support
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        krb5-user \
        libkrb5-3 \
        libgssapi-krb5-2 \
        keyutils \
        nfs-common \
        rpcbind \
        curl \
        nano \
        vim \
        sudo \
        procps \
        net-tools \
        iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Create a directory for mounting keytabs
RUN mkdir -p /etc/keytabs && chmod 755 /etc/keytabs

# Copy a template krb5.conf that will be overwritten by the mount
RUN echo '[libdefaults]' > /etc/krb5.conf && \
    echo '    default_realm = EXAMPLE.COM' >> /etc/krb5.conf && \
    echo '[realms]' >> /etc/krb5.conf && \
    echo '    EXAMPLE.COM = {' >> /etc/krb5.conf && \
    echo '        kdc = kdc.example.com' >> /etc/krb5.conf && \
    echo '        admin_server = kdc.example.com' >> /etc/krb5.conf && \
    echo '    }' >> /etc/krb5.conf && \
    chmod 644 /etc/krb5.conf

# Set up environment for Kerberos
ENV KRB5_CONFIG=/etc/krb5.conf

# Create an entrypoint script template
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
