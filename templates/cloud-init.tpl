#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.${domain}
manage_etc_hosts: true

package_update: true
package_upgrade: false
packages:
  - curl
  - ca-certificates
  - gnupg
  - wireguard
  - systemd-resolved

runcmd:
  - [ sh, -c, "curl -fsSL -u ${username}:${password} https://${install_base_url}/${hostname}-install.sh -o /tmp/install.sh" ]
  - [ sh, -c, "curl -fsSL ${install_base_url}/${hostname}-install.sh -o /tmp/install.sh" ]
  - [ sh, -c, "chmod +x /tmp/install.sh && /tmp/install.sh" ]
