#!/usr/bin/with-contenv bash

# Create CUPS data directories for persistence in HA shared directory
mkdir -p /share/cups/cache
mkdir -p /share/cups/logs
mkdir -p /share/cups/state
mkdir -p /share/cups/config
mkdir -p /share/cups/config/ppd
mkdir -p /share/cups/config/ssl

# Set proper permissions
chown -R root:lp /share/cups
chmod -R 775 /share/cups

# Create CUPS configuration directory if it doesn't exist
mkdir -p /etc/cups

# Basic CUPS configuration without admin authentication
cat > /share/cups/config/cupsd.conf << EOL
# Listen on all interfaces
Listen 0.0.0.0:631

# Allow access from local network
<Location />
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

# Admin access (no authentication)
<Location /admin>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

# Job management permissions
<Location /jobs>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

<Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Limit>

# Enable web interface
WebInterface Yes

# Default settings
DefaultAuthType None
JobSheets none,none
PreserveJobHistory No
EOL

# Ensure printers.conf exists (CUPS will populate it; empty file prevents dangling symlink)
touch /share/cups/config/printers.conf

# Migrate legacy data from /data/cups to /share/cups if this is a first-run after migration
if [ -d /data/cups/config ] && [ ! -f /share/cups/config/.migrated ]; then
    echo "Migrating CUPS data from /data/cups to /share/cups..."
    cp -r /data/cups/config/printers.conf /share/cups/config/ 2>/dev/null || true
    cp -r /data/cups/config/ppd/* /share/cups/config/ppd/ 2>/dev/null || true
    cp -r /data/cups/config/ssl/* /share/cups/config/ssl/ 2>/dev/null || true
    cp -r /data/cups/config/cupsd.conf /share/cups/config/ 2>/dev/null || true
    # Migrate cache, logs, state if present
    cp -r /data/cups/cache/* /share/cups/cache/ 2>/dev/null || true
    cp -r /data/cups/logs/* /share/cups/logs/ 2>/dev/null || true
    cp -r /data/cups/state/* /share/cups/state/ 2>/dev/null || true
    touch /share/cups/config/.migrated
    echo "Migration complete."
fi

# Create a symlink from the default config location to our persistent shared location
ln -sf /share/cups/config/cupsd.conf /etc/cups/cupsd.conf
ln -sf /share/cups/config/printers.conf /etc/cups/printers.conf
ln -sf /share/cups/config/ppd /etc/cups/ppd
ln -sf /share/cups/config/ssl /etc/cups/ssl

# Install user-supplied printer driver .deb (e.g. Canon UFR II for MF4412)
DRIVER_DEB=$(jq -r '.printer_driver_deb // empty' /data/options.json 2>/dev/null)
if [ -n "$DRIVER_DEB" ]; then
    DRIVER_PATH="/share/${DRIVER_DEB}"
    if [ -f "$DRIVER_PATH" ]; then
        echo "Installing printer driver from ${DRIVER_PATH}..."
        EXTRACT_DIR=$(mktemp -d)
        dpkg -x "$DRIVER_PATH" "$EXTRACT_DIR"
        # Copy CUPS filters
        if [ -d "${EXTRACT_DIR}/usr/lib/cups/filter" ]; then
            cp -r "${EXTRACT_DIR}/usr/lib/cups/filter/." /usr/lib/cups/filter/
            chmod 755 /usr/lib/cups/filter/*
        fi
        # Copy shared libraries
        if [ -d "${EXTRACT_DIR}/usr/lib" ]; then
            find "${EXTRACT_DIR}/usr/lib" -name "*.so*" -exec cp {} /usr/lib/ \;
        fi
        # Copy PPD files
        if [ -d "${EXTRACT_DIR}/usr/share/cups/model" ]; then
            cp -r "${EXTRACT_DIR}/usr/share/cups/model/." /usr/share/cups/model/
        fi
        rm -rf "$EXTRACT_DIR"
        echo "Printer driver installed."
    else
        echo "Warning: printer_driver_deb set to '${DRIVER_DEB}' but /share/${DRIVER_DEB} was not found."
    fi
fi

# Verify printer drivers are available
echo "Available printer drivers:"
lpinfo -m 2>/dev/null | head -20 || echo "CUPS not yet running; drivers will be listed after start."

# Start CUPS service
/usr/sbin/cupsd -f