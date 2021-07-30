#!/bin/bash

# Generate a gps steer file in the current directory for the
# specified particle, energy, and angles. Energy needs units,
# but angles always in degrees.
#
# Example:
# for particle in e- proton neutron \
#                 pi+ pi- pi0 mu+ mu- \
#                 kaon0L kaon0S kaon+ kaon- \
#                 gamma J/psi ; do
#   for energy in 100*MeV 150*MeV 200*MeV 300*MeV 500*MeV 750*MeV \
#                   1*GeV 1.5*GeV 2*GeV 3*GeV 5*GeV 7.5*GeV \
#                  10*GeV 15*GeV 20*GeV 30*GeV 50*GeV ; do
#     ./generate.sh $particle $energy
#   done
# done
#
# Allowable particle names (Geant4):
#      GenericIon, He3, alpha, anti_neutron
#      anti_nu_e, anti_nu_mu, anti_nu_tau, anti_proton
#      chargedgeantino, deuteron, e+, e-
#      eta, eta_prime, gamma, geantino
#      mu+, mu-, neutron, nu_e
#      nu_mu, nu_tau, opticalphoton, pi+
#      pi-, pi0, proton, tau+, tau-, triton,
#      D+, D-, D0, anti_D0, Ds+, Ds-, J/psi
#

PARTICLE=${1:-e-}
ENERGY=${2:-1\*GeV}
MINTHETA=${3:-45}
MAXTHETA=${4:-135}

DIR=$(dirname $0)
FILE=${PARTICLE//[\/_]/}_${ENERGY/\*/}_${MINTHETA}to${MAXTHETA}deg.steer
sed "s|%MINTHETA%|${MINTHETA}|g;s|%MAXTHETA%|${MAXTHETA}|g;
     s|%PARTICLE%|${PARTICLE}|g;s|%ENERGY%|${ENERGY}|g" ${DIR}/template.in \
   > ${FILE}
echo ${FILE}
