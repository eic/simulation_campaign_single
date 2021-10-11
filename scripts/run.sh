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
df -h
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
  SKIP_N_EVENTS=0
else
  TASK=$(printf ".%04d" ${3})
  SKIP_N_EVENTS=0
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

# Local temp dir
echo "SLURM_TMPDIR=${SLURM_TMPDIR:-}"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-}"
echo "SLURM_ARRAY_JOB_ID=${SLURM_ARRAY_JOB_ID:-}"
echo "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-}"
echo "_CONDOR_SCRATCH_DIR=${_CONDOR_SCRATCH_DIR:-}"
echo "OSG_WN_TMP=${OSG_WN_TMP:-}"
if [ -n "${SLURM_TMPDIR:-}" ] ; then
  TMPDIR=${SLURM_TMPDIR}
elif [ -n "${_CONDOR_SCRATCH_DIR:-}" ] ; then
  TMPDIR=${_CONDOR_SCRATCH_DIR}
else
  if [ -d "/scratch/slurm/${SLURM_JOB_ID:-}" ] ; then
    TMPDIR="/scratch/slurm/${SLURM_JOB_ID:-}"
  else
    TMPDIR=${TMPDIR:-/tmp}/${$}
  fi
fi
echo "TMPDIR=${TMPDIR}"
mkdir -p ${TMPDIR}
ls -al ${TMPDIR}

# Input file parsing
BASENAME=$(basename ${INPUT_FILE} .steer)
TASKNAME=${BASENAME}${TASK}
INPUT_DIR=$(dirname $(realpath --canonicalize-missing --relative-to=${BASEDIR} ${INPUT_FILE}))
# - file.hepmc              -> TAG="", and avoid double // in S3 location
# - EVGEN/file.hepmc        -> TAG="", and avoid double // in S3 location
# - EVGEN/DIS/file.hepmc    -> TAG="DIS"
# - EVGEN/DIS/NC/file.hepmc -> TAG="DIS/NC"
# - ../file.hepmc           -> error
if [ ! "${INPUT_DIR/\.\.\//}" = "${INPUT_DIR}" ] ; then
  echo "Error: Input file must be below current directory."
  exit
fi
INPUT_PREFIX=${INPUT_DIR/\/*/}
TAG=${INPUT_DIR/${INPUT_PREFIX}\//}
INPUT_DIR=${BASEDIR}/EVGEN/${TAG}
INPUT_TEMP=${TMPDIR}/EVGEN/${TAG}
mkdir -p ${INPUT_DIR} ${INPUT_TEMP}
INPUT_S3RO=${S3RODIR}/EVGEN/${TAG}
INPUT_S3RO=${INPUT_S3RO//\/\//\/}
TAG=${DETECTOR_VERSION}/${TAG}

# Output file names
LOG_DIR=${BASEDIR}/LOG/${TAG}
LOG_TEMP=${TMPDIR}/LOG/${TAG}
LOG_S3RW=${S3RWDIR}/LOG/${TAG}
LOG_S3RW=${LOG_S3RW//\/\//\/}
mkdir -p ${LOG_DIR} ${LOG_TEMP}
#
FULL_DIR=${BASEDIR}/FULL/${TAG}
FULL_TEMP=${TMPDIR}/FULL/${TAG}
FULL_S3RW=${S3RWDIR}/FULL/${TAG}
FULL_S3RW=${FULL_S3RW//\/\//\/}
mkdir -p ${FULL_DIR} ${FULL_TEMP}
#
RECO_DIR=${BASEDIR}/RECO/${TAG}
RECO_TEMP=${TMPDIR}/RECO/${TAG}
RECO_S3RW=${S3RWDIR}/RECO/${TAG}
RECO_S3RW=${RECO_S3RW//\/\//\/}
mkdir -p ${RECO_DIR} ${RECO_TEMP}


# Start logging block
{
date

# Internet connectivity check
if curl --connect-timeout 10 --retry 5 --silent --show-error ${S3URL} > /dev/null ; then
  echo "$(hostname) is online."
  ONLINE=true
else
  echo "$(hostname) is NOT online."
  ONLINE=""
fi

# Retrieve input file if S3_ACCESS_KEY and S3_SECRET_KEY in environment
if [ ! -f ${INPUT_FILE} ] ; then
  if [ -x ${MC} ] ; then
    if [ -n "${ONLINE:-}" ] ; then
      if [ -n "${S3_ACCESS_KEY:-}" -a -n "${S3_SECRET_KEY:-}" ] ; then
        ${MC} -C . config host add ${S3RO} ${S3URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY}
        ${MC} -C . config host list | grep -v SecretKey
        ${MC} -C . cp --disable-multipart --insecure ${INPUT_S3RO}/${BASENAME}.steer ${INPUT_DIR}
        ${MC} -C . config host remove ${S3RO}
      else
        echo "No S3 credentials. Provide (readonly) S3 credentials."
        exit -1
      fi
    else
      echo "No internet connection. Pre-cache input file."
      exit -1
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
  --outputFile ${FULL_TEMP}/${TASKNAME}.root
ls -al ${FULL_TEMP}/${TASKNAME}.root
rootls -t ${FULL_TEMP}/${TASKNAME}.root

# Data egress if S3RW_ACCESS_KEY and S3RW_SECRET_KEY in environment
if [ -x ${MC} ] ; then
  if [ -n "${ONLINE:-}" ] ; then
    if [ -n "${S3RW_ACCESS_KEY:-}" -a -n "${S3RW_SECRET_KEY:-}" ] ; then
      ${MC} -C . config host add ${S3RW} ${S3URL} ${S3RW_ACCESS_KEY} ${S3RW_SECRET_KEY}
      ${MC} -C . config host list | grep -v SecretKey
      ${MC} -C . cp --disable-multipart --insecure ${FULL_TEMP}/${TASKNAME}.root ${FULL_S3RW}
      ${MC} -C . config host remove ${S3RW}
    else
      echo "No S3 credentials."
    fi
  else
    echo "No internet connection."
  fi
fi
# Data egress to directory
if [ "${COPYFULL:-false}" == "true" ] ; then
  cp ${FULL_TEMP}/${TASKNAME}.root ${FULL_DIR}
  ls -al ${FULL_DIR}/${TASKNAME}.root
fi

# Get calibrations (e.g. 'acadia-v1.0-alpha' will pull artifacts from 'acadia')
if [ ! -d config ] ; then
  ${CALIBRATION:-/opt/benchmarks/physics_benchmarks}/bin/get_calibrations ${DETECTOR_VERSION/-*/}
fi

# Run reconstruction
date
export JUGGLER_N_EVENTS=2147483647
export JUGGLER_SIM_FILE="${FULL_TEMP}/${TASKNAME}.root"
for rec in ${RECONSTRUCTION:-/opt/benchmarks/physics_benchmarks/options}/*.py ; do
  unset tag
  [[ $(basename ${rec} .py) =~ (.*)\.(.*) ]] && tag=".${BASH_REMATCH[2]}"
  export JUGGLER_REC_FILE="${RECO_TEMP}/${TASKNAME}${tag:-}.root"
  /usr/bin/time -v \
    gaudirun.py ${rec} \
    || [ $? -eq 4 ]
  # FIXME why $? = 4
  ls -al ${JUGGLER_REC_FILE}
  rootls -t ${JUGGLER_REC_FILE}
done
ls -al ${RECO_TEMP}/${TASKNAME}*.root
rm -f ${FULL_TEMP}/${TASKNAME}.root

} 2>&1 | tee ${LOG_TEMP}/${TASKNAME}.out
ls -al ${LOG_TEMP}/${TASKNAME}.out

# Data egress if S3RW_ACCESS_KEY and S3RW_SECRET_KEY in environment
if [ -x ${MC} ] ; then
  if [ -n "${ONLINE:-}" ] ; then
    if [ -n "${S3RW_ACCESS_KEY:-}" -a -n "${S3RW_SECRET_KEY:-}" ] ; then
      ${MC} -C . config host add ${S3RW} ${S3URL} ${S3RW_ACCESS_KEY} ${S3RW_SECRET_KEY}
      ${MC} -C . config host list | grep -v SecretKey
      for i in ${RECO_TEMP}/${TASKNAME}*.root ; do
        ${MC} -C . cp --disable-multipart --insecure ${i} ${RECO_S3RW}
      done
      ${MC} -C . cp --disable-multipart --insecure ${LOG_TEMP}/${TASKNAME}.out ${LOG_S3RW}
      ${MC} -C . config host remove ${S3RW}
    else
      echo "No S3 credentials."
    fi
  else
    echo "No internet connection."
  fi
fi
# Data egress to directory
if [ "${COPYRECO:-false}" == "true" ] ; then
  cp ${RECO_TEMP}/${TASKNAME}*.root ${RECO_DIR}
  ls -al ${RECO_DIR}/${TASKNAME}*.root
fi
if [ "${COPYLOG:-false}" == "true" ] ; then
  cp ${LOG_TEMP}/${TASKNAME}.out ${LOG_DIR}
  ls -al ${LOG_DIR}/${TASKNAME}.out
fi
rm -f ${RECO_TEMP}/${TASKNAME}*.root

# closeout
date
