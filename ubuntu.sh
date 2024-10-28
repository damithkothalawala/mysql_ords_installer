#!/bin/bash
cat <<EOF
MIT License

Copyright (c) 2024 Damith Rushika Kothalawala

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

# Update package list
echo "Updating package list..."
sudo apt update

# Create necessary directories
echo "Creating necessary directories..."
sudo mkdir -p /opt/oracle/ords /opt/oracle/downloads

# Function to check if a package is installed
is_package_installed() {
    dpkg -s "$1" &> /dev/null
}

# Install MySQL server if not installed
if ! is_package_installed mysql-server; then
    echo "Installing MySQL server..."
    sudo apt install -y mysql-server
fi

# Install unzip if not installed
if ! is_package_installed unzip; then
    echo "Installing unzip..."
    sudo apt install -y unzip
fi

# Download and extract test_db if not already present
if [ ! -f /opt/oracle/downloads/test_db-1.0.7.tar.gz ]; then
    echo "Downloading and extracting test_db..."
    sudo wget -O /opt/oracle/downloads/test_db-1.0.7.tar.gz 'https://github.com/datacharmer/test_db/releases/download/v1.0.7/test_db-1.0.7.tar.gz'
    sudo tar -xf /opt/oracle/downloads/test_db-1.0.7.tar.gz -C /opt/oracle/downloads/
fi

# Import employees database if not already imported
if ! sudo mysql -e "USE employees" &> /dev/null; then
    echo "Importing employees database..."
    sudo mysql < /opt/oracle/downloads/test_db/employees.sql
fi

# Install Apache2 if not installed
if ! is_package_installed apache2; then
    echo "Installing Apache2..."
    sudo apt install -y apache2
fi

# Install snapd if not installed
if ! is_package_installed snapd; then
    echo "Installing snapd..."
    sudo apt install -y snapd
fi

# Install certbot if not installed
if ! command -v certbot &> /dev/null; then
    echo "Installing Certbot..."
    sudo snap install core; sudo snap refresh core
    sudo snap install --classic certbot
    sudo ln -s /snap/bin/certbot /usr/bin/certbot
fi

# Configure firewall rules with iptables
echo "Configuring firewall rules with ufw and iptables."
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
sudo ufw allow 80
sudo ufw allow 443 
sudo iptables -F

# Install Java if not installed
if ! is_package_installed openjdk-11-jdk-headless; then
    echo "Installing OpenJDK 11..."
    sudo apt install -y openjdk-11-jdk-headless
fi

# Download and install ORDS if not already installed
if [ ! -f /opt/oracle/ords/bin/ords ]; then
    echo "Downloading and installing ORDS..."
    sudo wget -O /opt/oracle/downloads/ords-24.3.0.262.0924.zip 'https://download.oracle.com/otn_software/java/ords/ords-24.3.0.262.0924.zip'
    sudo unzip /opt/oracle/downloads/ords-24.3.0.262.0924.zip -d /opt/oracle/ords/
fi

# Add ORDS to PATH
if ! echo "$PATH" | grep -q "/opt/oracle/ords/bin"; then
    echo "Adding ORDS to system PATH..."
    echo 'export PATH="$PATH:/opt/oracle/ords/bin"' | sudo tee /etc/profile.d/ords.sh
    source /etc/profile.d/ords.sh
fi

# Install MySQL Connector/J if not already present
if [ ! -f /opt/oracle/ords/lib/ext/mysql-connector-java-9.1.0.jar ]; then
    echo "Installing MySQL Connector/J..."
    sudo wget -O /opt/oracle/downloads/mysql-connector-j_9.1.0-1ubuntu22.04_all.deb 'https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-j_9.1.0-1ubuntu22.04_all.deb'
    sudo dpkg -i /opt/oracle/downloads/mysql-connector-j_9.1.0-1ubuntu22.04_all.deb
    sudo mkdir -p /opt/oracle/ords/lib/ext/
    sudo cp /usr/share/java/mysql-connector-* /opt/oracle/ords/lib/ext/
fi

# Generate a random password for ords_demo user
password=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 16)
echo -e "\n\nCreating MySQL user 'ords_demo' with password: $password\n\n"

# Create ords_demo user and grant privileges
echo "Creating ords_demo user and granting privileges..."
sudo mysql -e "CREATE USER IF NOT EXISTS 'ords_demo'@'localhost' IDENTIFIED BY '$password'; GRANT ALL PRIVILEGES ON employees.* TO 'ords_demo'@'localhost';"

# Configure ORDS
echo "Configuring ORDS..."
ORDS_CONFIG_DIR="/opt/oracle/ords/config"
sudo mkdir -p "$ORDS_CONFIG_DIR"
sudo /opt/oracle/ords/bin/ords --config "$ORDS_CONFIG_DIR" config set db.api.enabled true
sudo /opt/oracle/ords/bin/ords --config "$ORDS_CONFIG_DIR" config --db-pool ords_demo set db.connectionType customurl
sudo /opt/oracle/ords/bin/ords --config "$ORDS_CONFIG_DIR" config --db-pool ords_demo set db.customURL "jdbc:mysql://localhost/employees?sslMode=REQUIRED"
sudo /opt/oracle/ords/bin/ords --config "$ORDS_CONFIG_DIR" config --db-pool ords_demo set db.username ords_demo
sudo /opt/oracle/ords/bin/ords --config "$ORDS_CONFIG_DIR" config --db-pool ords_demo set db.credentialsSource request
sudo /opt/oracle/ords/bin/ords --config "$ORDS_CONFIG_DIR" config --db-pool ords_demo set restEnabledSql.active true
echo -n "$password" | sudo ords --config "$ORDS_CONFIG_DIR" config --db-pool ords_demo secret --password-stdin db.password

# Start ORDS on port 1987
echo "Starting ORDS on port 1987..."
sudo /opt/oracle/ords/bin/ords --config "$ORDS_CONFIG_DIR" serve --port 1987 &

# Wait for ORDS to start
echo "Waiting for ORDS to initialize..."
sleep 5

# Configure Apache virtual host
if [ ! -f /etc/apache2/sites-available/ords.conf ]; then
    echo "Configuring Apache virtual host..."
    nip_domain=$(curl -s https://api.ipify.org | sed -e 's/\./-/g').nip.io

    cat <<EOF | sudo tee /etc/apache2/sites-available/ords.conf
<VirtualHost *:80>
    ServerName $nip_domain

    <Proxy *>
        Require all granted
    </Proxy>
    ProxyPreserveHost On

    ProxyPass /ords http://localhost:1987/ords
    ProxyPassReverse /ords http://localhost:1987/ords

    RequestHeader set X-Forwarded-Host "$nip_domain"
    RequestHeader set Host "$nip_domain"
</VirtualHost>
EOF

    echo "Enabling Apache site and modules..."
    sudo a2ensite ords
    sudo a2enmod proxy headers proxy_http
    sudo systemctl reload apache2

    # Obtain SSL certificate with Certbot
    echo "Obtaining SSL certificate with Certbot..."
    sudo certbot --apache --agree-tos --no-eff-email --register-unsafely-without-email -d "$nip_domain"
fi

# Print the domain to access ORDS
echo -e "\n\nORDS is now accessible at: https://$nip_domain/ords/\n\n"
