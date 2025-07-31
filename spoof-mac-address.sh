/usr/local/sbin/spoof.sh;
echo "New Hostname:";
scutil --get HostName;
echo "Spoofed Mac Address";
ifconfig en0 | grep ether | awk '{print $2}';
echo "Your Original Hardware Mac Address"
networksetup -listallhardwareports | awk -v RS= '/en0/{print $NF}';
