# bash-rootkit
This is a "bash rootkit" I made from linux tips and tricks i found online.
First I used https://cyberchef.io/#recipe=To_Hex('%5C%5Cx',0)Pad_lines('Start',8,'printf%20%22') to encode the bash functions in "final_functions" and put them inside my beacon script.
Next I used THCs Bincrypter script to obfuscate my script, which makes the script unreadable and also when ran it only runs in memory.
