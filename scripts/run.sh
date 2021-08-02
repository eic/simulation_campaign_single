#!/bin/bash
set -Euo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
IFS=$'\n\t'

# Startup
date
hostname
whoami
pwd
ls -al

# Argument parsing
# - input file
INPUT_FILE=${1}
# - number of events
EVENTS_PER_TASK=${2:-10000}
# - current chunk
if [ ${#} -lt 3 ] ; then
  TASK=""
else
  TASK=$(printf ".%04d" ${3})
fi

# Output location
BASEDIR=${DATADIR:-${PWD}}
MINIOS3="S3rw/eictest/ATHENA"

# Input file parsing
BASENAME=$(basename ${INPUT_FILE} .steer)
TAG="${BASENAME//_/\/}"

# Create input file if not present
if [ ! -f ${INPUT_FILE} ] ; then
  if [[ ${BASENAME} =~ (.*)_(.*)_([0-9]+)to([0-9]+)deg ]] ; then
    INPUT_FILE=$($(dirname ${0})/generate.sh ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]})
    echo "Generated ${INPUT_FILE}"
  else
    echo "Error: Unable to generate input file."
    exit 1
  fi
fi

# Output file names
mkdir -p  ${BASEDIR}/FULL/SINGLE/${TAG}
FULL_FILE=${BASEDIR}/FULL/SINGLE/${TAG}/${BASENAME}${TASK}.root
FULL_S3RW=${MINIOS3}/FULL/SINGLE/${TAG}/${BASENAME}${TASK}.root
FULL_S3RW=${FULL_S3RW//\/\//\/}
mkdir -p  ${BASEDIR}/GEOM/SINGLE/${TAG}
GEOM_ROOT=${BASEDIR}/GEOM/SINGLE/${TAG}/${BASENAME}${TASK}.geom
mkdir -p  ${BASEDIR}/RECO/SINGLE/${TAG}
RECO_FILE=${BASEDIR}/RECO/SINGLE/${TAG}/${BASENAME}${TASK}.root
RECO_S3RW=${MINIOS3}/RECO/SINGLE/${TAG}/${BASENAME}${TASK}.root
RECO_S3RW=${RECO_S3RW//\/\//\/}

# Detector description
COMPACT_FILE=/opt/detector/share/athena/athena.xml

# Check for existing full simulation on local node
if [ ! -f ${FULL_FILE} -o ! -d ${GEOM_ROOT} ] ; then
  # Load container environment
  source /opt/detector/setup.sh

  /usr/bin/time -v \
    npsim \
    --runType run \
    --printLevel WARNING \
    --enableGun \
    --steeringFile ${INPUT_FILE} \
    --numberOfEvents ${EVENTS_PER_TASK} \
    --compactFile ${COMPACT_FILE} \
    --outputFile ${FULL_FILE}
  rootls -t "${FULL_FILE}"

  # Take snapshot of geometry and versions
  mkdir -p ${GEOM_ROOT}
  cp -r /opt/detector/* ${GEOM_ROOT}
  eic-info > ${GEOM_ROOT}/eic-info.txt
  echo -n "export LD_LIBRARY_PATH=${GEOM_ROOT}/lib:$" > ${GEOM_ROOT}/setup.sh
  echo "LD_LIBRARY_PATH" >> ${GEOM_ROOT}/setup.sh

  # Data egress if config.json in $PWD
  if [ -x /usr/local/bin/mc -a -f ./config.json ] ; then
    if ping -c 1 -w 5 google.com > /dev/null ; then
      /usr/local/bin/mc -C ./config.json cp "${FULL_FILE}" "${FULL_S3RW}"
    else
      echo "No internet connection."
    fi
  fi
fi

# Load snapshot environment
source ${GEOM_ROOT}/setup.sh

# Run reconstruction
export JUGGLER_SIM_FILE="${FULL_FILE}"
export JUGGLER_REC_FILE="${RECO_FILE}"
export JUGGLER_N_EVENTS=2147483647
export JUGGLER_DETECTOR=athena
export DETECTOR_PATH="${GEOM_ROOT}/share/athena"
/usr/bin/time -v \
xenv -x /usr/local/Juggler.xenv \
  gaudirun.py /opt/benchmarks/reconstruction_benchmarks/benchmarks/full/options/full_reconstruction.py \
    || [ $? -eq 4 ]
# FIXME why $? = 4
rootls -t "${RECO_FILE}"

# Data egress if config.json in $PWD
if [ -x /usr/local/bin/mc -a -f ./config.json ] ; then
  if ping -c 1 -w 5 google.com > /dev/null ; then
    /usr/local/bin/mc -C ./config.json cp "${RECO_FILE}" "${RECO_S3RW}"
  else
    echo "No internet connection."
  fi
fi

# closeout
ls -al ${FULL_FILE}
ls -al ${RECO_FILE}
date
