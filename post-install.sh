#!/bin/bash

# Post install script after a debian install
# Old version > new Ansible playbooks

# Check privileges
if [[ "${UID}" -ne 0 ]]
then
 echo 'Must execute with sudo or root' >&2
 exit 1
fi

# Update and upgrade 
sudo apt update -y
sudo apt upgrade -y
flatpak update -y

# Install AIDE
apt install aide aide-common -y 
aideinit
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

# Enable UFW firewall
systemctl is-enabled ufw
sudo ufw enable 

# Firewall allow openssh
sudo ufw allow OpenSSH

# Install OpenSSH
sudo apt install openssh-server -y

# Enable AuditD
systemctl --now enable auditd 

# Disabling non-key and root login
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config 
echo "PermitRootLogin no" >> /etc/ssh/sshd_config 
echo "PermitEmptyPasswords no" /etc/ssh/sshd_config

# Automatic downloads of security updates
sudo apt-get install -y unattended-upgrades
echo "Unattended-Upgrade::Allowed-Origins {
#   "${distro_id}:${distro_codename}-security";
#//  "${distro_id}:${distro_codename}-updates";
#//  "${distro_id}:${distro_codename}-proposed";
#//  "${distro_id}:${distro_codename}-backports";
#Unattended-Upgrade::Automatic-Reboot "true"; 
#}; " >> /etc/apt/apt.conf.d/50unattended-upgrades

# Fail2Ban install 
sudo apt-get install -y fail2ban
sudo systemctl start fail2ban
sudo systemctl enable fail2ban

echo "
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 4
" >> /etc/fail2ban/jail.local

sudo service ssh restart  

#Install openscap
sudo apt install libopenscap8 -y
