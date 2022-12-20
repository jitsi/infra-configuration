mkdir /etc/prosody-jvb/

# prosody data_path
mkdir /var/lib/prosody-jvb/
chown prosody:prosody /var/lib/prosody-jvb/

cp /lib/systemd/system/prosody.service /lib/systemd/system/prosody-jvb.service
sed -i 's/Description=Prosody XMPP Server/Description=Prosody JVB XMPP Server/' /lib/systemd/system/prosody-jvb.service
sed -i 's/ExecStart=\/usr\/bin\/prosody/ExecStart=\/usr\/bin\/prosody --config \/etc\/prosody-jvb\/prosody.cfg.lua/' /lib/systemd/system/prosody-jvb.service
sed -i 's/RuntimeDirectory=prosody/RuntimeDirectory=prosody-jvb/' /lib/systemd/system/prosody-jvb.service
sed -i 's/ConfigurationDirectory=prosody/ConfigurationDirectory=prosody-jvb/' /lib/systemd/system/prosody-jvb.service
sed -i 's/StateDirectory=prosody/StateDirectory=prosody-jvb/' /lib/systemd/system/prosody-jvb.service
sed -i 's/LogsDirectory=prosody/LogsDirectory=prosody-jvb/' /lib/systemd/system/prosody-jvb.service
sed -i 's/PIDFile=prosody\/prosody.pid/PIDFile=prosody-jvb\/prosody.pid/' /lib/systemd/system/prosody-jvb.service
