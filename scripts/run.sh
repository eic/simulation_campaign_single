#!/bin/bash
set -Euo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
IFS=$'\n\t'

# Check arguments
if [ $# -lt 1 ] ; then
  echo "Usage: "
  echo "  $0 <input> [n_chunk=10000] [i_chunk=]"
  echo
  echo "A typical npsim run requires from 0.5 to 5 core-seconds per event,"
  echo "and uses under 3 GB of memory. The output ROOT file for"
  echo "10k events take up about 2 GB in disk space."
  exit
fi

# Startup
date
hostname
whoami
pwd
ls -al

# Load container environment (include ${DETECTOR_VERSION})
source /opt/detector/setup.sh
echo "DETECTOR_VERSION=${DETECTOR_VERSION}"

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

# S3 locations
MC="/usr/local/bin/mc"
S3URL="https://dtn01.sdcc.bnl.gov:9000"
S3RO="S3"
S3RW="S3rw"
S3RODIR="${S3RO}/eictest/ATHENA"
S3RWDIR="${S3RW}/eictest/ATHENA"

# Input file parsing
BASENAME=$(basename ${INPUT_FILE} .steer)
TAG="${BASENAME//_/\/}"
mkdir -p   ${BASEDIR}/EVGEN/
INPUT_S3RO=${S3RODIR}/EVGEN/SINGLE/${BASENAME}.steer
INPUT_S3RO=${INPUT_S3RO//\/\//\/}

# Output file names
mkdir -p ${BASEDIR}/LOG/${DETECTOR_VERSION}/SINGLE/${TAG}
LOG_FILE=${BASEDIR}/LOG/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.out
LOG_S3RW=${S3RWDIR}/LOG/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.out
LOG_S3RW=${LOG_S3RW//\/\//\/}
mkdir -p  ${BASEDIR}/FULL/${DETECTOR_VERSION}/SINGLE/${TAG}
FULL_FILE=${BASEDIR}/FULL/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.root
FULL_S3RW=${S3RWDIR}/FULL/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.root
FULL_S3RW=${FULL_S3RW//\/\//\/}
mkdir -p  ${BASEDIR}/RECO/${DETECTOR_VERSION}/SINGLE/${TAG}
RECO_FILE=${BASEDIR}/RECO/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.root
RECO_S3RW=${S3RWDIR}/RECO/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.root
RECO_S3RW=${RECO_S3RW//\/\//\/}

# Local temp dir
if [ -n "${SLURM_TMPDIR:-}" ] ; then
  TMPDIR=${SLURM_TMPDIR}
else
  if [ -d "/scratch/slurm/${SLURM_JOB_ID:-}" ] ; then
    TMPDIR="/scratch/slurm/${SLURM_JOB_ID:-}"
  else
    TMPDIR=${TMPDIR:-/tmp}/${$}
  fi
fi
echo "TMPDIR=${TMPDIR}"
mkdir -p  ${TMPDIR}/FULL/${DETECTOR_VERSION}/SINGLE/${TAG}/
FULL_TEMP=${TMPDIR}/FULL/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.root
mkdir -p  ${TMPDIR}/RECO/${DETECTOR_VERSION}/SINGLE/${TAG}/
RECO_TEMP=${TMPDIR}/RECO/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.root
mkdir -p ${TMPDIR}/LOG/${DETECTOR_VERSION}/SINGLE/${TAG}/
LOG_TEMP=${TMPDIR}/LOG/${DETECTOR_VERSION}/SINGLE/${TAG}/${BASENAME}${TASK}.out

# Start logging block
{

# Retrieve input file if S3_ACCESS_KEY and S3_SECRET_KEY in environment
if [ ! -f ${INPUT_FILE} ] ; then
  if [ -x ${MC} ] ; then
    if curl --connect-timeout 5 ${S3URL} > /dev/null ; then
      if [ -n "${S3_ACCESS_KEY:-}" -a -n "${S3_SECRET_KEY:-}" ] ; then
        ${MC} -C . config host add ${S3RO} ${S3URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY}
        ${MC} -C . cp --disable-multipart "${INPUT_S3RO}" "${INPUT_FILE}"
        ${MC} -C . config host remove ${S3RO}
      else
        echo "No S3 credentials. Provide (readonly) S3 credentials."
        exit
      fi
    else
      echo "No internet connection. Pre-cache input file."
      exit
    fi
  fi
fi

# Run simulation
/usr/bin/time -v \
  npsim \
  --runType run \
  --random.seed ${3:-1} \
  --random.enableEventSeed \
  --printLevel WARNING \
  --enableGun \
  --steeringFile ${INPUT_FILE} \
  --numberOfEvents ${EVENTS_PER_TASK} \
  --part.minimalKineticEnergy 1*TeV \
  --compactFile ${DETECTOR_PATH}/${JUGGLER_DETECTOR}.xml \
  --outputFile ${FULL_TEMP}
rootls -t "${FULL_TEMP}"
if [ -n "${COPYFULL:-}" ] ; then
  cp "${FULL_TEMP}" "${FULL_FILE}"
fi

# Data egress if S3RW_ACCESS_KEY and S3RW_SECRET_KEY in environment
if [ -x ${MC} ] ; then
  if curl --connect-timeout 5 ${S3URL} > /dev/null ; then
    if [ -n "${S3RW_ACCESS_KEY:-}" -a -n "${S3RW_SECRET_KEY:-}" ] ; then
      ${MC} -C . config host add ${S3RW} ${S3URL} ${S3RW_ACCESS_KEY} ${S3RW_SECRET_KEY}
      ${MC} -C . cp --disable-multipart "${FULL_TEMP}" "${FULL_S3RW}"
      ${MC} -C . config host remove ${S3RW}
    else
      echo "No S3 credentials."
    fi
  else
    echo "No internet connection."
  fi
fi

# Get calibrations (e.g. 'acadia-v1.0-alpha' will pull artifacts from 'acadia')
if [ ! -d config ] ; then
  ${RECONSTRUCTION:-/opt/benchmarks/physics_benchmarks}/bin/get_calibrations ${DETECTOR_VERSION/-*/}
fi

# Run reconstruction
export JUGGLER_SIM_FILE="${FULL_TEMP}"
export JUGGLER_REC_FILE="${RECO_TEMP}"
export JUGGLER_N_EVENTS=2147483647
/usr/bin/time -v \
  gaudirun.py ${RECONSTRUCTION:-/opt/benchmarks/physics_benchmarks}/options/reconstruction.py \
    || [ $? -eq 4 ]
# FIXME why $? = 4
rootls -t "${RECO_TEMP}"
if [ -n "${COPYRECO:-}" ] ; then
  cp "${RECO_TEMP}" "${RECO_FILE}"
}

} 2>&1 | tee "${LOG_TEMP}"
if [ -n "${COPYLOG:-}" ] ; then
  cp "${LOG_TEMP}" "${LOG_FILE}"
}

# Data egress if S3RW_ACCESS_KEY and S3RW_SECRET_KEY in environment
if [ -x ${MC} ] ; then
  if curl --connect-timeout 5 ${S3URL} > /dev/null ; then
    if [ -n "${S3RW_ACCESS_KEY:-}" -a -n "${S3RW_SECRET_KEY:-}" ] ; then
      ${MC} -C . config host add ${S3RW} ${S3URL} ${S3RW_ACCESS_KEY} ${S3RW_SECRET_KEY}
      ${MC} -C . cp --disable-multipart "${RECO_TEMP}" "${RECO_S3RW}"
      ${MC} -C . cp --disable-multipart "${LOG_TEMP}" "${LOG_S3RW}"
      ${MC} -C . config host remove ${S3RW}
    else
      echo "No S3 credentials."
    fi
  else
    echo "No internet connection."
  fi
fi

# closeout
rm -f "${INPUT_TEMP}"
rm -f "${FULL_TEMP}"
rm -f "${RECO_TEMP}"
if [ -n "${COPYFULL:-}" ] ; then
  ls -al "${FULL_FILE}"
fi
if [ -n "${COPYRECO:-}" ] ; then
  ls -al "${RECO_FILE}"
fi
if [ -n "${COPYLOG:-}" ] ; then
  ls -al "${LOG_FILE}"
fi
date
