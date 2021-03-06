#!/bin/bash -e
: <<DD
Deploy a tor relay on a server which is managed by a third party

There are many server owners who want to provide resources
for the Tor network, but don't have the time or desire to take
care of the administration.

With this script, a server operator can install puppet and tor.

After all that is done, a volunteer can edit the tor relay
configuration and control the tor service.
All this without direct access to the owner's server.
DD

export DEBIAN_FRONTEND="noninteractive"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

PUPPETMASTER="mcp.loki.tel"
PUPPETAGENT="ci.loki.tel"
PUPPETENV="pipeline"

# Prepare apt
apt-get update
apt-get -y install apt-utils apt-transport-https
apt-get -y install wget sudo openssl gnupg lsb-release python3-dev cron

CODENAME=$(lsb_release --codename --short)
PASSWORD=$(openssl rand -base64 16)
SYSTEMCTL=$(which systemctl)

# Install puppetlabs repo
wget -O /tmp/puppet.deb https://apt.puppetlabs.com/puppet7-release-bullseye.deb
dpkg -i /tmp/puppet.deb

# Install torproject repo
cat >/etc/apt/sources.list.d/tor.list <<EOF
deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org $CODENAME main
deb-src [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org $CODENAME main
EOF
wget -qO- https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --dearmor | tee /usr/share/keyrings/tor-archive-keyring.gpg >/dev/null

# Install puppet, tor, nyx, obfs4 and torprojects keyring
apt-get update
apt-get install -y tor nyx obfs4proxy deb.torproject.org-keyring puppet-agent

$SYSTEMCTL disable --now puppet

# Print
echo -e "\n\nThe following packages are now available:\n"
apt list --installed -- *tor* -- *obfs4* -- *puppet* -- *nyx* --

# Prepare the tor-user
TORHOME=$(printf ~debian-tor)
chsh --shell /bin/bash debian-tor

: <<DEPRECATED
# Setup local puppet
mkdir -p $TORHOME/.puppetlabs/etc/puppet/
cat > $TORHOME/.puppetlabs/etc/puppet/puppet.conf <<EOF
[main]
server = $PUPPETMASTER
EOF

# Setup cronjob
echo "*/10 * * * * /opt/puppetlabs/bin/puppet agent --test" > $TORHOME/cron
su - debian-tor -c "touch ~/.hushlogin"
su - debian-tor -c "crontab cron"
DEPRECATED

chown -R debian-tor:debian-tor "$TORHOME" /etc/tor/

# Setup sudo for debian-tor
cat >/etc/sudoers.d/debian-tor <<EOF
debian-tor ALL=(ALL) NOPASSWD: /usr/bin/id -u
debian-tor ALL=(ALL) NOPASSWD: $SYSTEMCTL * tor.service
EOF

# Set a password for the user and use it once to prevent the
# interactive query of sudo.
passwd debian-tor <<EOF
$PASSWORD
$PASSWORD
EOF

su - debian-tor -c "echo $PASSWORD | sudo -S $SYSTEMCTL status tor.service"

if [ "$(su - debian-tor -c 'sudo id -u')" == 0 ]; then
  echo -e "\nCongratulations, sudo works!\n"
else
  echo -e "\nSorry, something went wrong..\n"
  exit 1
fi

# Check tor status and run puppet
su - debian-tor -c "puppet agent --server $PUPPETMASTER --certname $PUPPETAGENT --environment=$PUPPETENV --test --waitforcert 1 --summarize"
su - debian-tor -c "sudo $SYSTEMCTL status tor.service"
su - debian-tor -c "crontab -l"

echo -e "\n\nUsed variables:\n\n \
        PUPPETMASTER=$PUPPETMASTER\n \
        PUPPETAGENT=$PUPPETAGENT\n \
        PUPPETENV=$PUPPETENV\n \
        CODENAME=$CODENAME\n \
        PASSWORD=$PASSWORD\n \
        TORHOME=$TORHOME\n \
        SYSTEMCTL=$SYSTEMCTL"
exit 0
