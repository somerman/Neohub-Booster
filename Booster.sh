#!/bin/bash
# A simple script to read the temperature from the neohub and boost the immersion heater if the temperature is below a threshold.
#There is no scheduler, run as a cron job every hour or so, the script will check the temperature and boost if necessary.
#Note the actual temperature is controlled by the immersion thermostat.
printf 'Neohub booster \n'
logger "Neohub booster"
printf "%(%H:%M)T\n"
#setup error handling for the coproc pipes
set -euo pipefail
#get args
neohubip=$1
threshold_temp=${2:-50}
boosttime=${3:-3600}
# this is the name of the switch to turn on and off, as set in the app or got from the zones
neoswitchname=${4:-"Immersion water switch"}
neostatmon=${5:-11} # this is the neostat id of the temp monitoring device
echo "Neohub IP: $neohubip" 
neohubport=4242

coproc CLIENT { nc $neohubip $neohubport; }

# To send a command to the neohub, needs space then \0 and \n (hex 000a) to delimit
#printf "{\"GET_DEVICES\":0} \0\n" 

function isAway() {
  printf "{\"GET_LIVE_DATA\":0} \0\n" >&"${CLIENT[1]}"
  if read -r -t 5    -u "${CLIENT[0]}" response; then
  #two lotsof array nesting, the value we need is in the 4th element of the array, 
  #which is a key value pair, so we split that on the : to get the value
    IFS=',' read -r -a array <<< "$response"
    #echo "Neohub : $array"
    IFS=':' read -r key value <<< "${array[3]}"
    #echo "Key: $key, Value: $value"
    if [[ "$value" == "true" ]]; then
      exit 0
    fi
  else #can't communicate so exit with an error code, the cleanup function will be called by the trap
    printf 'ERROR: coprocess timed out after 5s\n' >&2
    printf 'Neohub : %s\n' "$response"  
    cleanup
    
  fi
}

function get_zones() {
  printf "{\"GET_ZONES\":0} \0\n" >&"${CLIENT[1]}"
  if read -r -t 5  -u "${CLIENT[0]}" zones; then
    printf 'Got: %s\n' "$zones"
    
  else #can't communicate so exit with an error code, the cleanup function will be called by the trap
    printf 'ERROR: coprocess timed out after 5s\n' >&2
    printf 'Neohub : %s\n' "$zones"  
    cleanup
    #return 1
  fi
}
function get_latest_temp() {
  local response
  printf "{\"GET_TEMPLOG\":$neostatmon} \0\n" >&"${CLIENT[1]}"
  # read the return pipe with a 5 second timeout. The -u attaches the FD to the read and places the result in 'response'
  if read -r -t 5  -u "${CLIENT[0]}" response; then
    printf 'Got: %s\n' "$response"
    str_len=${#response}
    str_pos=$str_len-8
    latest_temp=${response:$str_pos:2}
    echo $latest_temp
  else
    printf 'ERROR: coprocess timed out after 5s\n'  >&2
    printf 'Neohub : %s\n' "$response" 
    logger "Neohub booster script exit timeout" 
    cleanup
    
  fi
}
# the main loop, 
#first, find out if the system is set to way, if it is, just exit because we don't want to boost 
#so interrogate the live data for the Away flag.
isAway
#not away so carry on 
#get the zones and then get the latest temp, if it is below the threshold, boost for 1 hour
get_zones
if get_latest_temp; then
  echo "Latest temp: $latest_temp"
  int_temp=$((latest_temp))
  if (($((latest_temp)) < $((threshold_temp)))); then
    echo "Temp is below threshold, boosting"
    printf "{\"TIMER_ON\": \"$neoswitchname\"} \0\n" >&"${CLIENT[1]}"
    sleep $boosttime
    printf "{\"TIMER_OFF\":\"$neoswitchname\"} \0\n" >&"${CLIENT[1]}"
    echo "Boosting complete"
  else
    echo "Temp is above threshold, not boosting"
  fi
else
  echo "Failed to get latest temp"
fi

# when stuff goes wrong or on normal exit, kill the coproc pipes
function cleanup() {
  :
  #Close write FD to signal EOF
  exec {CLIENT[0]}>&- 2>/dev/null || true
  exec {CLIENT[1]}>&- 2>/dev/null || true
  # Give it 2 seconds to exit gracefully
  local deadline=$(( $(date +%s) + 2 ))
  while kill -0 "$CLIENT_PID" 2>/dev/null; do
    (( $(date +%s) > deadline )) && kill -9 "$CLIENT_PID" 2>/dev/null; break #send the PID to the error FD (2) 
    sleep 0.2
  done
  wait "$CLIENT_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Exiting"
logger "Neohub booster script exiting"
exit 0

