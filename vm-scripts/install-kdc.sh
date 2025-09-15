#!/usr/bin/env bash

# This script installs and configures MIT Kerberos KDC

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Color print functions
print_red() { echo -e "${RED}$*${NC}"; }
print_green() { echo -e "${GREEN}$*${NC}"; }
print_yellow() { echo -e "${YELLOW}$*${NC}"; }

# Auto-detect IP address from ens3 interface
HOST_IP=$(ip addr show ens3 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
if [[ -z "${HOST_IP:-}" ]]; then
    print_red "ERROR: Could not detect IP address from ens3 interface"
    exit 1
fi

# Parameters - NFS server IP is required for multi-server setup
if [[ -z "${1:-}" ]]; then
    print_red "ERROR: NFS server IP is required"
    echo "Usage: $0 <nfs_server_ip>"
    exit 1
fi

NFS_SERVER_IP="$1"

# Expand IPs to full nip.io hostnames
KDC_HOSTNAME="kdc-${HOST_IP}.nip.io"
NFS_HOSTNAME="nfs-${NFS_SERVER_IP}.nip.io"

# Configuration
REALM="EXAMPLE.COM"
ADMIN_PRINCIPAL="admin/admin"
KDC_PASSWORD="changeme123"

# Users to provision
USERS=("user10002" "user10003" "user10004" "user10005" "user10006")

echo "=== Installing Kerberos KDC on Ubuntu 24.04 (Multi-Server) ==="
echo "KDC IP: ${HOST_IP} -> ${KDC_HOSTNAME}"
echo "NFS Server IP: ${NFS_SERVER_IP} -> ${NFS_HOSTNAME}"

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
        kdc = ${KDC_HOSTNAME}
        admin_server = ${KDC_HOSTNAME}
        default_domain = example.com
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
    .example.com = ${REALM}
    example.com = ${REALM}

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
kadmin/${KDC_HOSTNAME}@${REALM}    *
EOF

# Initialize KDC database
if [[ -f "/var/lib/krb5kdc/principal" ]]; then
    print_yellow "KDC database already exists, removing and recreating..."
    systemctl stop krb5-kdc krb5-admin-server || true
    rm -rf /var/lib/krb5kdc/*
fi
print_yellow "Creating KDC database..."
printf '%s\n%s\n' "${KDC_PASSWORD}" "${KDC_PASSWORD}" | kdb5_util create -s

# Start KDC services
systemctl enable krb5-kdc
systemctl enable krb5-admin-server
systemctl start krb5-kdc
systemctl start krb5-admin-server

# Create admin principal
print_yellow "Creating admin principal..."
printf '%s\n%s\n' "${KDC_PASSWORD}" "${KDC_PASSWORD}" | kadmin.local -q "addprinc ${ADMIN_PRINCIPAL}"

# Create NFS service principal
print_yellow "Creating NFS service principal..."
kadmin.local -q "addprinc -randkey nfs/${NFS_HOSTNAME}@${REALM}"
kadmin.local -q "addprinc -randkey nfs/${NFS_SERVER_IP}@${REALM}"

# Create user principals with specific passwords
print_yellow "Creating user principals..."
for user in "${USERS[@]}"; do
    echo "Creating user principal ${user}..."
    kadmin.local -q "addprinc -pw password ${user}@${REALM}"
done

# Create keytabs directory
mkdir -p /etc/keytabs
chmod 755 /etc/keytabs
rm -f /etc/keytabs/*.keytab
rm -f /etc/krb5.keytab

# Export NFS service keytab
print_yellow "Creating NFS service keytab..."
kadmin.local -q "ktadd -k /etc/keytabs/nfs.keytab nfs/${NFS_HOSTNAME}@${REALM}"
kadmin.local -q "ktadd -k /etc/keytabs/nfs.keytab nfs/${NFS_SERVER_IP}@${REALM}"
chmod 644 /etc/keytabs/nfs.keytab

# Export user keytabs
print_yellow "Creating user keytabs..."
for user in "${USERS[@]}"; do
    echo "Creating user keytab for ${user}..."
    kadmin.local -q "ktadd -k /etc/keytabs/${user}.keytab ${user}@${REALM}"
    chmod 644 "/etc/keytabs/${user}.keytab"
done

# Set up NFS service principal for GSS authentication
if [[ -f "/etc/keytabs/nfs.keytab" ]]; then
    print_yellow "Setting up NFS service principal for GSS authentication..."
    # Clean up any existing system keytab to avoid duplicates
    sudo rm -f /etc/krb5.keytab
    kadmin.local -q "ktadd -k /etc/krb5.keytab nfs/${NFS_HOSTNAME}@${REALM}"
    kadmin.local -q "ktadd -k /etc/krb5.keytab nfs/${NFS_SERVER_IP}@${REALM}"
    chmod 600 /etc/krb5.keytab
    print_green "✓ NFS service principal added to system keytab"
else
    print_red "WARNING: /etc/keytabs/nfs.keytab not found. KDC may not be set up yet."
fi

# Extract NFS server IP from hostname (format: nfs-IP.nip.io)
NFS_IP=$(echo "$NFS_HOSTNAME" | sed 's/nfs-\([0-9.]*\)\.nip\.io/\1/')

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
print_yellow "=== Setting up HTTP server for keytab distribution ==="
apt-get install -y nginx

# Create keytab distribution directory
mkdir -p /var/www/html/keytabs

# Regenerate all keytabs to ensure KVNO consistency
print_yellow "Regenerating keytabs for HTTP distribution with current KVNOs..."
rm -f /var/www/html/keytabs/*.keytab

# Regenerate NFS keytab with current KVNO
kadmin.local -q "ktadd -k /var/www/html/keytabs/nfs.keytab nfs/${NFS_HOSTNAME}@${REALM}"
kadmin.local -q "ktadd -k /var/www/html/keytabs/nfs.keytab nfs/${NFS_SERVER_IP}@${REALM}"

# Regenerate user keytabs with current KVNO
for user in "${USERS[@]}"; do
    kadmin.local -q "ktadd -k /var/www/html/keytabs/${user}.keytab ${user}@${REALM}"
done

chmod 644 /var/www/html/keytabs/*.keytab
cp /etc/krb5.conf /var/www/html/

# Configure nginx for keytab distribution
cat > /etc/nginx/sites-available/keytabs <<EOF
server {
    listen 8080;
    server_name _;

    # Root location for directory listing
    location / {
        root /var/www/html;
        autoindex on;
        try_files \$uri \$uri/ =404;
    }

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

# Remove default nginx site and enable our keytab site
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/keytabs /etc/nginx/sites-enabled/
systemctl enable nginx
systemctl restart nginx

# Verify files are accessible
print_yellow "=== Verifying keytab files are accessible ==="
ls -la /var/www/html/
ls -la /var/www/html/keytabs/
chown -R www-data:www-data /var/www/html/
chmod -R 755 /var/www/html/

print_green "=== KDC Installation Complete ==="
echo "KDC Server: ${KDC_HOSTNAME}"
echo "Realm: ${REALM}"
echo "Admin Principal: ${ADMIN_PRINCIPAL}"
echo "Password: ${KDC_PASSWORD}"
echo ""
echo "Keytabs and krb5.conf available at: http://${KDC_HOSTNAME}:8080/"
