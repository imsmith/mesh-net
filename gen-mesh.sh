#!/bin/bash

set -euo pipefail

# Prompt user for domain and ULA prefix
echo -n "Enter domain name (e.g., mesh.local): "
read DOMAIN

echo -n "Enter ULA IPv6 prefix (leave blank to auto-generate): "
read ULA_PREFIX

if [[ -z "$ULA_PREFIX" ]]; then
  RNDHEX=$(hexdump -n 5 -e '/1 "%02x"' /dev/urandom)
  ULA_PREFIX="fd${RNDHEX:0:2}:${RNDHEX:2:4}:${RNDHEX:6:4}"
  echo "Generated ULA prefix: $ULA_PREFIX"
fi

# Define hostnames using periodic table elements
PERIODIC_TABLE=(Hydrogen Helium Lithium Beryllium Boron Carbon Nitrogen Oxygen Fluorine Neon Sodium Magnesium Aluminum Silicon Phosphorus Sulfur Chlorine Argon Potassium Calcium Scandium Titanium Vanadium Chromium Manganese Iron Cobalt Nickel Copper Zinc Gallium Germanium Arsenic Selenium Bromine Krypton Rubidium Strontium Yttrium Zirconium Niobium Molybdenum Technetium Ruthenium Rhodium Palladium Silver Cadmium Indium Tin Antimony Tellurium Iodine Xenon Cesium Barium Lanthanum Cerium Praseodymium Neodymium Promethium Samarium Europium Gadolinium Terbium Dysprosium Holmium Erbium Thulium Ytterbium Lutetium Hafnium Tantalum Tungsten Rhenium Osmium Iridium Platinum Gold Mercury Thallium Lead Bismuth Polonium Astatine Radon Francium Radium Actinium Thorium Protactinium Uranium Neptunium Plutonium Americium Curium Berkelium Californium Einsteinium Fermium Mendelevium Nobelium Lawrencium Rutherfordium Dubnium Seaborgium Bohrium Hassium Meitnerium Darmstadtium Roentgenium Copernicium Nihonium Flerovium Moscovium Livermorium Tennessine Oganesson)
NUM_HOSTS=${#PERIODIC_TABLE[@]}

VAULT_ADDR="https://127.0.0.1:8200"
INSTALL_DIR="./installers"
mkdir -p "$INSTALL_DIR"

CSV_FILE="members.${DOMAIN}.csv"
echo "hostname,public_key,ipv6_address" > "$CSV_FILE"

ZONE_FILE="zone.${DOMAIN}.txt"
echo -e "\$ORIGIN ${DOMAIN}.\n\$TTL 86400" > "$ZONE_FILE"

for i in "${!PERIODIC_TABLE[@]}"; do
  ATOMIC_NUM=$((i + 1))
  HOSTNAME="$(echo "${PERIODIC_TABLE[$i]}" | tr '[:upper:]' '[:lower:]')"
  IP6_SUFFIX=$ATOMIC_NUM
  FULL_IP6="${ULA_PREFIX}::${IP6_SUFFIX}"

  # Generate keys if not in Vault
  if ! vault kv get -field=private_key secret/wireguard/$HOSTNAME &>/dev/null; then
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    PRESHARED_KEY=$(wg genpsk)
    vault kv put secret/wireguard/$HOSTNAME \
      private_key="$PRIVATE_KEY" \
      public_key="$PUBLIC_KEY" \
      preshared_key="$PRESHARED_KEY"
  else
    PRIVATE_KEY=$(vault kv get -field=private_key secret/wireguard/$HOSTNAME)
    PUBLIC_KEY=$(vault kv get -field=public_key secret/wireguard/$HOSTNAME)
  fi

  echo "$HOSTNAME,$PUBLIC_KEY,$FULL_IP6" >> "$CSV_FILE"
  echo "$HOSTNAME	IN	AAAA	$FULL_IP6" >> "$ZONE_FILE"

done

# Read all host info into arrays
mapfile -t HOST_ENTRIES < <(tail -n +2 "$CSV_FILE")

for ENTRY in "${HOST_ENTRIES[@]}"; do
  IFS="," read -r HOSTNAME PUBKEY IP6 <<< "$ENTRY"
  PRIVATE_KEY=$(vault kv get -field=private_key secret/wireguard/$HOSTNAME)
  PRESHARED_KEY=$(vault kv get -field=preshared_key secret/wireguard/$HOSTNAME)

  CONFIG="[Interface]
Address = $IP6/64
PrivateKey = $PRIVATE_KEY
DNS = ${ULA_PREFIX}::1

"
  HOSTS_FILE=""
  for PEER_ENTRY in "${HOST_ENTRIES[@]}"; do
    IFS="," read -r PEER_HOST PEER_PUBKEY PEER_IP6 <<< "$PEER_ENTRY"
    HOSTS_FILE+="$PEER_IP6 ${PEER_HOST}.${DOMAIN} ${PEER_HOST}
"
    if [[ "$PEER_HOST" != "$HOSTNAME" ]]; then
      CONFIG+="[Peer]
PublicKey = $PEER_PUBKEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = $PEER_IP6/128
Endpoint = ${PEER_HOST}.${DOMAIN}:51820
PersistentKeepalive = 25

"
    fi
  done

  cat > "$INSTALL_DIR/${HOSTNAME}-install.sh" <<EOF
#!/bin/bash

set -e

apt-get update
apt-get install -y wireguard systemd-resolved

# Retrieve systemd unit if needed
curl -o /etc/systemd/system/wg-quick@wg0.service https://raw.githubusercontent.com/imsmith/mesh-net/main/systemd/wg-quick@wg0.service

mkdir -p /etc/wireguard
echo "$CONFIG" > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# Set up DNS resolution for mesh domain
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/mesh-domains.conf <<EOM
[Resolve]
Domains=${DOMAIN}
DNS=${ULA_PREFIX}::1
MulticastDNS=yes
FallbackDNS=
EOM

cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak || true
sed -i 's/^#*DNSStubListener=.*/DNSStubListener=yes/' /etc/systemd/resolved.conf

systemctl daemon-reexec
systemctl enable systemd-resolved
systemctl restart systemd-resolved

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Add hosts file entries for all mesh nodes
cat >> /etc/hosts <<EOL
$HOSTS_FILE
EOL
EOF
  chmod +x "$INSTALL_DIR/${HOSTNAME}-install.sh"
done

echo "Setup complete. Output files:"
echo " - CSV of members: $CSV_FILE"
echo " - DNS zone file: $ZONE_FILE"
echo " - Installers: $INSTALL_DIR/*.sh"
