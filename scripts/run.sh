#!/bin/bash
set -Euo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
IFS=$'\n\t'

# Load job environment (includes secrets, so delete when read)
if [ -f environment.sh ] ; then
  grep -v SECRET environment.sh
  source environment.sh
  rm environment.sh
fi

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
echo "date sys: $(date)"
echo "date web: $(date -d "$(curl -Is --max-redirs 0 google.com 2>&1 | grep Date: | cut -d' ' -f2-7)")"
echo "hostname: $(hostname -f)"
echo "uname:    $(uname -a)"
echo "whoami:   $(whoami)"
echo "pwd:      $(pwd)"
echo "site:     ${GLIDEIN_Site:-}"
echo "resource: ${GLIDEIN_ResourceName:-}"
echo "http_proxy: ${http_proxy:-}"
df -h --exclude-type=fuse --exclude-type=tmpfs
ls -al
test -f .job.ad && cat .job.ad
test -f .machine.ad && cat .machine.ad
eic-info

# Load container environment
export CONFIG=${DETECTOR_CONFIG:-}
source /opt/detector/${DETECTOR:-epic}-${DETECTOR_VERSION:-nightly}/setup.sh
export DETECTOR_CONFIG=epic${CONFIG:+_${CONFIG}}

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

# Retry function
function retry {
  local n=0
  local max=5
  local delay=20
  while [[ $n -lt $max ]] ; do
    n=$((n+1))
    s=0
    "$@" || s=$?
    [ $s -eq 0 ] && {
      return $s
    }
    [ $n -ge $max ] && {
      echo "Failed after $n retries, exiting with $s"
      return $s
    }
    echo "Retrying in $delay seconds..."
    sleep $delay
  done
}

# S3 locations
MC="/usr/local/bin/mc"
S3URL="https://dtn01.sdcc.bnl.gov:9000"
S3RO="S3"
S3RW="S3rw"
S3RODIR="${S3RO}/eictest/EPIC"
S3RWDIR="${S3RW}/eictest/EPIC"

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
TAG=${DETECTOR_VERSION}/${DETECTOR_CONFIG}/${TAG}

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

# Internet connectivity check
if curl --connect-timeout 30 --retry 5 --silent --show-error ${S3URL} > /dev/null ; then
  echo "$(hostname) is online."
  export ONLINE=true
else
  echo "$(hostname) is NOT online."
  if which tracepath ; then
    tracepath -b -p 9000 dtn01.sdcc.bnl.gov
  fi
  export ONLINE=""
fi

# Start logging block
{
date

# Test reconstruction before simulation
export JUGGLER_N_EVENTS=2147483647
export JUGGLER_SIM_FILE="${FULL_TEMP}/${TASKNAME}.edm4hep.root"
export JUGGLER_REC_FILE="${RECO_TEMP}/${TASKNAME}.edm4hep.root"
for rec in ${RECONSTRUCTION:-/opt/benchmarks/physics_benchmarks/options}/*.py ; do
  python ${rec}
done

# Retrieve input file if S3_ACCESS_KEY and S3_SECRET_KEY in environment
if [ ! -f ${INPUT_FILE} ] ; then
  if [ -x ${MC} ] ; then
    if [ -n "${ONLINE:-}" ] ; then
      if [ -n "${S3_ACCESS_KEY:-}" -a -n "${S3_SECRET_KEY:-}" ] ; then
        MC_CONFIG=$(mktemp -d $PWD/mc_config.XXXX)
        retry ${MC} -C ${MC_CONFIG} config host add ${S3RO} ${S3URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY}
        retry ${MC} -C ${MC_CONFIG} config host list ${S3RO} | grep -v SecretKey
        retry ${MC} -C ${MC_CONFIG} cp --disable-multipart --insecure ${INPUT_S3RO}/${BASENAME}.steer ${INPUT_DIR}
        retry ${MC} -C ${MC_CONFIG} config host remove ${S3RO}
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
prmon \
  --filename ${LOG_TEMP}/${TASKNAME}.npsim.prmon.txt \
  --json-summary ${LOG_TEMP}/${TASKNAME}.npsim.prmon.json \
  -- \
npsim \
  --runType run \
  --random.seed ${3:-1} \
  --random.enableEventSeed \
  --printLevel WARNING \
  --enableGun \
  --steeringFile ${INPUT_FILE} \
  --numberOfEvents ${EVENTS_PER_TASK} \
  --part.minimalKineticEnergy 1*TeV \
  --filter.tracker 'edep0' \
  --compactFile ${DETECTOR_PATH}/${DETECTOR_CONFIG}.xml \
  --outputFile ${FULL_TEMP}/${TASKNAME}.edm4hep.root
ls -al ${FULL_TEMP}/${TASKNAME}.edm4hep.root

# Data egress if S3RW_ACCESS_KEY and S3RW_SECRET_KEY in environment
if [ "${UPLOADFULL:-false}" == "true" ] ; then
  if [ -x ${MC} ] ; then
    if [ -n "${ONLINE:-}" ] ; then
      if [ -n "${S3RW_ACCESS_KEY:-}" -a -n "${S3RW_SECRET_KEY:-}" ] ; then
        MC_CONFIG=$(mktemp -d $PWD/mc_config.XXXX)
        retry ${MC} -C ${MC_CONFIG} config host add ${S3RW} ${S3URL} ${S3RW_ACCESS_KEY} ${S3RW_SECRET_KEY}
        retry ${MC} -C ${MC_CONFIG} config host list ${S3RW} | grep -v SecretKey
        retry ${MC} -C ${MC_CONFIG} cp --disable-multipart --insecure ${FULL_TEMP}/${TASKNAME}.edm4hep.root ${FULL_S3RW}/
        retry ${MC} -C ${MC_CONFIG} config host remove ${S3RW}
      else
        echo "No S3 credentials."
      fi
    else
      echo "No internet connection."
    fi
  fi
fi
# Data egress to directory
if [ "${COPYFULL:-false}" == "true" ] ; then
  cp ${FULL_TEMP}/${TASKNAME}.edm4hep.root ${FULL_DIR}
  ls -al ${FULL_DIR}/${TASKNAME}.edm4hep.root
fi

# Run juggler reconstruction
date
for rec in ${RECONSTRUCTION:-/opt/benchmarks/physics_benchmarks/options}/*.py ; do
  unset tag
  [[ $(basename ${rec} .py) =~ (.*)\.(.*) ]] && tag=".${BASH_REMATCH[2]}"
  export JUGGLER_REC_FILE="${RECO_TEMP}/${TASKNAME}${tag:-}.juggler.tree.edm4eic.root"
  /usr/bin/time -v \
    gaudirun.py ${rec} \
    || [ $? -eq 4 ]
  # FIXME why $? = 4
  ls -al ${JUGGLER_REC_FILE}
done
ls -al ${RECO_TEMP}/${TASKNAME}*.juggler.tree.edm4eic.root

# Run eicrecon reconstruction
date
prmon \
  --filename ${LOG_TEMP}/${TASKNAME}.eicrecon.prmon.txt \
  --json-summary ${LOG_TEMP}/${TASKNAME}.eicrecon.prmon.json \
  -- \
run_eicrecon_reco_flags.py "${JUGGLER_SIM_FILE}" "${RECO_TEMP}/${TASKNAME}.eicrecon" -Pjana:warmup_timeout=0 -Pjana:timeout=0 -Pplugins=janadot
if [ -f jana.dot ] ; then mv jana.dot ${LOG_TEMP}/${TASKNAME}.eicrecon.dot ; fi
ls -al ${RECO_TEMP}/${TASKNAME}*.eicrecon.tree.edm4eic.root

} 2>&1 | grep -v SECRET_KEY | tee ${LOG_TEMP}/${TASKNAME}.out
ls -al ${LOG_TEMP}/${TASKNAME}.out

# Data egress if S3RW_ACCESS_KEY and S3RW_SECRET_KEY in environment
if [ -x ${MC} ] ; then
  if [ -n "${ONLINE:-}" ] ; then
    if [ -n "${S3RW_ACCESS_KEY:-}" -a -n "${S3RW_SECRET_KEY:-}" ] ; then
      MC_CONFIG=$(mktemp -d $PWD/mc_config.XXXX)
      retry ${MC} -C ${MC_CONFIG} config host add ${S3RW} ${S3URL} ${S3RW_ACCESS_KEY} ${S3RW_SECRET_KEY}
      retry ${MC} -C ${MC_CONFIG} config host list ${S3RW} | grep -v SecretKey
      for i in ${RECO_TEMP}/${TASKNAME}*.edm4eic.root ; do
        retry ${MC} -C ${MC_CONFIG} cp --disable-multipart --insecure ${i} ${RECO_S3RW}/
      done
      retry ${MC} -C ${MC_CONFIG} cp --disable-multipart --insecure ${LOG_TEMP}/${TASKNAME}.* ${LOG_S3RW}/
      retry ${MC} -C ${MC_CONFIG} config host remove ${S3RW}
    else
      echo "No S3 credentials."
    fi
  else
    echo "No internet connection."
  fi
fi
# Data egress to directory
if [ "${COPYRECO:-false}" == "true" ] ; then
  cp ${RECO_TEMP}/${TASKNAME}*.edm4eic.root ${RECO_DIR}
  ls -al ${RECO_DIR}/${TASKNAME}*.edm4eic.root
fi
if [ "${COPYLOG:-false}" == "true" ] ; then
  cp ${LOG_TEMP}/${TASKNAME}.out ${LOG_DIR}
  ls -al ${LOG_DIR}/${TASKNAME}.out
fi

# closeout
date
find ${TMPDIR}
du -sh ${TMPDIR}

# Remove full simulation
rm -f ${FULL_TEMP}/${TASKNAME}.edm4hep.root
rm -f ${RECO_TEMP}/${TASKNAME}*.edm4eic.root
