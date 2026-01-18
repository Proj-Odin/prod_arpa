# prod_arpa

chmod +x setup_conky_overlay.sh
sudo ./setup_conky_overlay.sh

# Start Conky immediately (without logging out)
conky -c ~/.config/conky/conky.conf

# Checkmk
sudo chmod +x /usr/lib/check_mk_agent/local/hdd_burnin_status.sh

