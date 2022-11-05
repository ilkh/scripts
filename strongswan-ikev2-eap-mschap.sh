firewall-cmd --permanent --zone=public --add-masquerade
firewall-cmd --permanent --zone=public --add-service="ipsec"
firewall-cmd --permanent --zone=public --add-service="http"
firewall-cmd --reload

sed "s|enabled=0|enabled=1|g" -i /etc/yum.repos.d/oracle-epel-ol8.repo
dnf install strongswan certbot

certbot certonly --standalone --agree-tos --no-eff-email --email <email> -d <domain>

ln -s /etc/letsencrypt/live/<domain>/chain.pem /etc/strongswan/swanctl/x509ca
ln -s /etc/letsencrypt/live/<domain>/fullchain.pem /etc/strongswan/swanctl/x509
ln -s /etc/letsencrypt/live/<domain>/privkey.pem /etc/strongswan/swanctl/private


###
cat > /etc/systemd/system/certbot-renew.service <<EOF
[Unit]
Description=Certbot Renewal

[Service]
ExecStart=/usr/bin/certbot renew --post-hook "systemctl reload strongswan.service"
EOF

cat > /etc/systemd/system/certbot-renew.timer <<EOF
[Unit]
Description=Timer for Certbot Renewal

[Timer]
OnBootSec=5m
OnUnitActiveSec=30d

[Install]
WantedBy=multi-user.target
EOF


###
cat > /etc/sysctl.d/90-strongswan.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
sysctl -p


###
cat > /etc/strongswan/swanctl/conf.d/ike2-rw-eap.conf <<EOF
connections {
   rw-eap {
      # server ip
      local_addrs = <internal_server_ip_behind_nat>
      pools = rw_pool
      version = 2
      # macos fix
      send_certreq = no
      send_cert = always
      # allow multiple connections from same ip
      unique = never
      proposals = aes128-sha256-sha1-x25519-modp2048-modp1024
      local {
         auth = pubkey
         certs = fullchain.pem
         id = <domain>
      }
      remote {
         auth = eap-mschapv2
         eap_id = %any
      }
      children {
         net {
            # # Disable rekey for mikrotik
            # rekey_time=0s
            # split tunnel
            local_ts = 0.0.0.0/0, 10.10.10.0/24
            esp_proposals = aes128-sha256-sha1-x25519-modp2048-modp1024
         }
      }
   }
}

secrets {
   eap-user1 {
      id = user1
      secret = pass1
   }
   eap-user2 {
      id = user2
      secret = pass2
   }
}

pools {
    rw_pool {
        addrs = 10.10.10.0/24
        dns = 1.1.1.1, 8.8.8.8
    }
}
EOF

###
cat > ~/swanctl.te <<EOF
module swanctl 1.0;
require {
        type ipsec_mgmt_t;
        type ipsec_conf_file_t;
        type var_run_t;
        type cert_t;
        class dir read;
        class lnk_file read;
        class sock_file write;
        class file map;
}
allow ipsec_mgmt_t cert_t:file map;
allow ipsec_mgmt_t ipsec_conf_file_t:dir read;
allow ipsec_mgmt_t ipsec_conf_file_t:lnk_file read;
allow ipsec_mgmt_t var_run_t:sock_file write;
EOF

checkmodule -M -m ~/swanctl.te -o ~/swanctl.mod
semodule_package -m ~/swanctl.mod -o ~/swanctl.pp 
semodule -v -i ~/swanctl.pp
###

systemctl enable --now strongswan.service 
systemctl enable --now certbot-renew.timer
