date; pwd; df -h; free -m
cat /proc/cpuinfo | grep "model name"
wget "https://master.dl.sourceforge.net/project/itk-snap/itk-snap/4.4.0-alpha3/itksnap-4.4.0-alpha3-20250612-Linux-x86_64.tar.gz"
tar -xvf itksnap-4.4.0-alpha3-20250612-Linux-x86_64.tar.gz
mv itksnap-4.4.0-alpha3-20250612-Linux-x86_64 itksnap
mv itksnap /root

# Install FSL, latest version
sudo apt-get update &
wget https://fsl.fmrib.ox.ac.uk/fsldownloads/fslconda/releases/getfsl.sh 
wget https://fsl.fmrib.ox.ac.uk/fsldownloads/fslconda/releases/fslinstaller.py
chmod 700 ./getfsl.sh
#./getfsl.sh &
chmod 700 ./fslinstaller.py

# Install ANTs
wget "https://dicom.offis.de/download/dcmtk/dcmtk369/bin/dcmtk-3.6.9-linux-x86_64-static.tar.bz2" &
wget https://github.com/ANTsX/ANTs/releases/download/v2.6.2/ants-2.6.2-ubuntu-24.04-X64-gcc.zip 
unzip ants-2.6.2-ubuntu-24.04-X64-gcc.zip
mv ants-2.6.2 /root
rm ants-2.6.2-ubuntu-24.04-X64-gcc.zip
export ANTS_PATH="/root/ants-2.6.2"
export ANTS_BIN="$ANTS_HOME/bin"
chmod -R 700 $ANTS_BIN
echo 'export ANTS_HOME="/root/ants-2.6.2";ANTS_PATH="$ANTS_HOME";ANTS_BIN="$ANTS_HOME/bin";FSLDIR="/root/fsl"' >> ~/.bashrc
echo 'export PATH="$PATH:$ANTS_BIN:$ANTS_PATH:$ANTS_HOME:$FSLDIR:$FSLDIR/bin:/bin:/usr/bin:/usr/local/bin:/root/bin:/root/itksnap/bin:/root/itksnap/bin:/workspace/brainstemx-full/src:/root/dcmtk-3.6.9-linux-x86_64-static:/root/dcmtk-3.6.9-linux-x86_64-static/bin:/root/ants/bin:/root/itksnap/bin:root/fsl/bin"' >> ~/.bashrc
source ~/.bashrc
cp ~/.bashrc ~/.bash_profile
cp ~/.bash_profile ~/.profile
# Install uv
wget https://astral.sh/uv/install.sh
chmod 700 ./install.sh 
sh ./install.sh
# sudo apt-get install -y libpng-dev libjpeg-dev libtiff-dev imagemagick 
uv add -r requirements.txt
wget "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20250506/dcm2niix_lnx.zip"
unzip dcm2niix_lnx.zip
mv dcm2niix /root/bin
#cp /root/bin/dcm2niix /usr/bin
apt-get install -y dcm2niix
tar -xjf dcmtk-3.6.9-linux-x86_64-static.tar.bz2
mv dcmtk-3.6.9-linux-x86_64-static /root
chmod -R 700 /root/itksnap/bin
chmod -R 700 /root
mkdir ~/DICOM
touch ~/DICOM/Image1
touch /usr/bin/freeview && chmod 700 /usr/bin/freeview  #as the script expects it

source ~/.bashrc
#testing
echo "Environment setup done.."
du -hs
apt-get install -y parallel
export PATH="$PATH:$ANTS_BIN:$ANTS_PATH:$ANTS_HOME:/root/fsl:/root/fsl/bin:$FSLDIR:$FSLDIR/bin:/bin:/usr/bin:/usr/local/bin:/root/bin:/root/itksnap/bin:/root/itksnap/bin:/workspace/brainstemx-full/src:/root/dcmtk-3.6.9-linux-x86_64-static:/root/dcmtk-3.6.9-linux-x86_64-static/bin"
date; pwd; df -h; free -m
cat /proc/cpuinfo | grep "model name"
uv run ./fslinstaller.py
top -b -n1 | head -10
chmod -R 755 src/pipeline.sh src/*.py tests/* config/*.sh src/modules/*
uv run ./src/modules/environment.sh


