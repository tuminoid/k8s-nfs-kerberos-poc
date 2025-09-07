#!/usr/bin/env bash
# Ubuntu 24.04 Kerberos KDC Installation Script
# Run this on a dedicated VM for the KDC server

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Auto-detect IP address from ens3 interface
HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Could not detect IP address from ens3 interface"
    exit 1
fi

# Configuration
REALM="EXAMPLE.COM"
DOMAIN="example.com"
KDC_SERVER="kdc.${DOMAIN}"
NFS_SERVER="nfs.${DOMAIN}"
ADMIN_PRINCIPAL="admin/admin"
KDC_PASSWORD="changeme123"

echo "=== Installing Kerberos KDC on Ubuntu 24.04 ==="
echo "Detected Host IP: ${HOST_IP}"

# Set up /etc/hosts entry for KDC
echo "Setting up /etc/hosts entry for KDC..."
sed -i "/${KDC_SERVER}/d" /etc/hosts
echo "${HOST_IP} ${KDC_SERVER}" >> /etc/hosts
echo "✓ KDC hostname configured in /etc/hosts"

# Update system
apt-get update && apt-get upgrade -y

# Install Kerberos KDC packages
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    krb5-kdc \
    krb5-admin-server \
    krb5-config \
    krb5-user \
    pwgen

# Create KDC configuration
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    kdc_timesync = 1
    ccache_type = 4
    forwardable = true
    proxiable = true
    dns_lookup_realm = false
    dns_lookup_kdc = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    rdns = false

[realms]
    ${REALM} = {
        kdc = ${KDC_SERVER}
        admin_server = ${KDC_SERVER}
        default_domain = ${DOMAIN}
        database_name = /var/lib/krb5kdc/principal
        acl_file = /etc/krb5kdc/kadm5.acl
        key_stash_file = /etc/krb5kdc/stash
        kdc_ports = 750,88
        max_life = 10h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        master_key_type = des3-hmac-sha1
        supported_enctypes = aes256-cts:normal aes128-cts:normal des3-hmac-sha1:normal arcfour-hmac:normal
    }

[domain_realm]
    .${DOMAIN} = ${REALM}
    ${DOMAIN} = ${REALM}

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOF

# Create KDC database directory
mkdir -p /var/lib/krb5kdc
mkdir -p /etc/krb5kdc

# Create KDC ACL file
cat > /etc/krb5kdc/kadm5.acl <<EOF
*/admin@${REALM}    *
admin/admin@${REALM}    *
kadmin/admin@${REALM}    *
kadmin/changepw@${REALM}    *
kadmin/${KDC_SERVER}@${REALM}    *
EOF

# Initialize KDC database
if [ -f /var/lib/krb5kdc/principal ]; then
    echo "KDC database already exists, removing and recreating..."
    systemctl stop krb5-kdc krb5-admin-server || true
    rm -rf /var/lib/krb5kdc/*
fi
echo "Creating KDC database..."
printf '%s\n%s\n' "${KDC_PASSWORD}" "${KDC_PASSWORD}" | kdb5_util create -s

# Start KDC services
systemctl enable krb5-kdc
systemctl enable krb5-admin-server
systemctl start krb5-kdc
systemctl start krb5-admin-server

# Create admin principal
echo "Creating admin principal..."
printf '%s\n%s\n' "${KDC_PASSWORD}" "${KDC_PASSWORD}" | kadmin.local -q "addprinc ${ADMIN_PRINCIPAL}"

# Create NFS service principal
echo "Creating NFS service principal..."
kadmin.local -q "addprinc -randkey nfs/${NFS_SERVER}@${REALM}"
kadmin.local -q "addprinc -randkey nfs/${HOST_IP}@${REALM}"

# Create user principals with specific passwords
echo "Creating user principals..."
for user in user10002 user10003 user10004; do
    echo "Creating user principal ${user}..."
    kadmin.local -q "addprinc -pw password ${user}@${REALM}"
done

# Create keytabs directory
mkdir -p /etc/keytabs
chmod 755 /etc/keytabs

# Clean up any existing keytabs and recreate
echo "Cleaning up existing keytabs..."
rm -f /etc/keytabs/*.keytab

# Export NFS service keytab
echo "Creating NFS service keytab..."
kadmin.local -q "ktadd -k /etc/keytabs/nfs.keytab nfs/${NFS_SERVER}@${REALM}"
kadmin.local -q "ktadd -k /etc/keytabs/nfs.keytab nfs/${HOST_IP}@${REALM}"
chmod 644 /etc/keytabs/nfs.keytab

# Export user keytabs
echo "Creating user keytabs..."
for user in user10002 user10003 user10004; do
    echo "Creating user keytab for ${user}..."
    kadmin.local -q "ktadd -k /etc/keytabs/${user}.keytab ${user}@${REALM}"
    chmod 644 /etc/keytabs/${user}.keytab
done

# Set up NFS service principal for GSS authentication
echo "Setting up NFS service principal for GSS authentication..."
if [ -f /etc/keytabs/nfs.keytab ]; then
    echo "Adding NFS service principal to system keytab..."
    # Clean up any existing system keytab to avoid duplicates
    sudo rm -f /etc/krb5.keytab
    kadmin.local -q "ktadd -k /etc/krb5.keytab nfs/${NFS_SERVER}@${REALM}"
    kadmin.local -q "ktadd -k /etc/krb5.keytab nfs/${HOST_IP}@${REALM}"
    chmod 600 /etc/krb5.keytab
    echo "✓ NFS service principal added to system keytab"
else
    echo "WARNING: /etc/keytabs/nfs.keytab not found. KDC may not be set up yet."
fi

# Configure firewall
echo "=== Configuring UFW firewall ==="
ufw --force enable
ufw allow 88/tcp    # Kerberos KDC
ufw allow 88/udp    # Kerberos KDC
ufw allow 749/tcp   # Kerberos admin
ufw allow 749/udp   # Kerberos admin
ufw allow 22/tcp    # SSH
ufw allow from 10.0.0.0/8  # Allow internal networks
ufw allow from 172.16.0.0/12  # Allow Docker networks
ufw allow from 192.168.0.0/16  # Allow private networks

# Setup log rotation
cat > /etc/logrotate.d/krb5 <<EOF
/var/log/krb5kdc.log {
    weekly
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 640 root root
    postrotate
        systemctl reload krb5-kdc
    endscript
}

/var/log/kadmin.log {
    weekly
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 640 root root
    postrotate
        systemctl reload krb5-admin-server
    endscript
}
EOF

# Create HTTP server for keytab distribution
echo "=== Setting up HTTP server for keytab distribution ==="
apt-get install -y nginx

# Create keytab distribution directory
mkdir -p /var/www/html/keytabs
cp /etc/keytabs/*.keytab /var/www/html/keytabs/
cp /etc/krb5.conf /var/www/html/

# Configure nginx for keytab distribution
cat > /etc/nginx/sites-available/keytabs <<EOF
server {
    listen 8080;
    server_name _;

    location /keytabs/ {
        root /var/www/html;
        autoindex on;
        add_header Content-Type application/octet-stream;
    }

    location /krb5.conf {
        root /var/www/html;
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf /etc/nginx/sites-available/keytabs /etc/nginx/sites-enabled/
systemctl enable nginx
systemctl restart nginx

# Open port for keytab distribution
ufw allow 8080/tcp

echo "=== KDC Installation Complete ==="
echo "KDC Server: ${KDC_SERVER}"
echo "Realm: ${REALM}"
echo "Admin Principal: ${ADMIN_PRINCIPAL}"
echo "Password: ${KDC_PASSWORD}"
echo ""
echo "Keytabs and krb5.conf available at: http://${KDC_SERVER}:8080/"
