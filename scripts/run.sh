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
SINGLETAG="SINGLE/${BASENAME//_/\/}"
mkdir -p  ${BASEDIR}/FULL/${SINGLETAG}
FULL_FILE=${BASEDIR}/FULL/${SINGLETAG}/${BASENAME}${TASK}.root
FULL_S3RW=${MINIOS3}/FULL/${SINGLETAG}/${BASENAME}${TASK}.root
mkdir -p  ${BASEDIR}/GEOM/${SINGLETAG}
GEOM_ROOT=${BASEDIR}/GEOM/${SINGLETAG}/${BASENAME}${TASK}.geom
mkdir -p  ${BASEDIR}/RECO/${SINGLETAG}
RECO_FILE=${BASEDIR}/RECO/${SINGLETAG}/${BASENAME}${TASK}.root
RECO_S3RW=${MINIOS3}/RECO/${SINGLETAG}/${BASENAME}${TASK}.root

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
/usr/bin/time -v \
xenv -x /usr/local/Juggler.xenv \
  gaudirun.py /opt/benchmarks/reconstruction_benchmarks/benchmarks/full/options/full_reconstruction.py
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
