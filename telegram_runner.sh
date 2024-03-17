#!/bin/bash

SCRIPT_HOME="$(cd -- "$MY_PATH" && pwd)"

DATA_HOME=${HOME}/.data/tgsystem

TG_QUEUE=${DATA_HOME}/telegram_queue.dat
ALLOWED_TGS_DIR=${DATA_HOME}/allowed_telegrams

NS_API_URL="https://www.nationstates.net/cgi-bin/api.cgi"
NS_API_CLIENT_KEY=$(cat ${DATA_HOME}/apiclientkey.dat)
NS_API_USER_AGENT=$(cat ${DATA_HOME}/useragent.dat)

EL_SPREADSHEET_ID=$(cat ${DATA_HOME}/exclusionlist.dat | grep "^ID=" | cut -d'=' -f2-)
EL_RANGE_NAME=$(cat ${DATA_HOME}/exclusionlist.dat | grep "^Range=" | cut -d'=' -f2-)
EL_GOOGLE_SHEETS_KEY_FILE=$(cat ${DATA_HOME}/exclusionlist.dat | grep "^KeyFile=" | cut -d'=' -f2-)

LOGS_DIR=${HOME}/logs/tgsystem
LOG=${LOGS_DIR}/telegram_runner.log
XML_LOG=${LOGS_DIR}/telegram_runner_xml.log

idle_time=0

timestamp() {
  echo -n "$(date '+%Y-%m-%d %H:%M:%S')"
}

function update_exclusion_list() {

  range_value=$(python ${SCRIPT_HOME}/read_exclusion_list.py $EL_SPREADSHEET_ID $EL_RANGE_NAME $EL_GOOGLE_SHEETS_KEY_FILE)
  range_value=$(echo "$range_value" | awk '!seen[$0]++')

  if [ ! "$range_value" == "No data found." ]; then
    if [ ! -z "$range_value" ]; then
      echo "[$(timestamp)] Updated recruitment exclusion list." >> ${LOG}
      echo "$range_value" > ${DATA_HOME}/recruitment_exclusion_list.txt
    else
      echo "[$(timestamp)] Problem updating recruitment exclusion list." >> ${LOG}
    fi
  else
    echo "[$(timestamp)] Problem updating recruitment exclusion list." >> ${LOG}
  fi
}

function send_telegram() {

  tg_curl_data="a=sendTG&client=${NS_API_CLIENT_KEY}&tgid=${tg_id}&key=${tg_key}&to=${tg_target}"
  echo "[$(timestamp)] Sending recruitment telegram to ${tg_target}" >> ${LOG}

  response=$(curl -A "${NS_API_USER_AGENT}" "${NS_API_URL}" --data "$tg_curl_data" --http1.1)
  echo "$response"
  echo "[$(timestamp)] $response" >> ${LOG}

  idle_time=0

}


function run_recruitment_tg() {
	
  echo "Queuing up Recruitment Telegram to ${tg_target}."
  echo "[$(timestamp)] Queuing up recruitment telegram to ${tg_target}." >> ${LOG}

  wait_time=$(( 180 - $idle_time ))
  if [ $wait_time -gt 0 ]; then
    talk_while_sleeping $wait_time
  fi

  update_exclusion_list

  curl_data="nation=${tg_target}&q=region+tgcanrecruit&from=the_north_pacific"
  response=$(curl -A "${NS_API_USER_AGENT}" "${NS_API_URL}" --data "$curl_data" --http1.1)

  echo $response | xmllint --format - > /tmp/tgcanrecruitcheck.xml
  echo "[$(timestamp)] $response" >> ${XML_LOG}

  current_region=$(grep -oP '<REGION>\K[^<]+' /tmp/tgcanrecruitcheck.xml | tr [:upper:] [:lower:] | tr ' ' '_')
  tgcanrecruit=$(grep -oP '<TGCANRECRUIT>\K[^<]+' /tmp/tgcanrecruitcheck.xml)

  if [ $tgcanrecruit -eq 1 ]; then
    if ! grep -q "^${current_region}$" ${DATA_HOME}/recruitment_exclusion_list.txt; then
      send_telegram
    else
	    echo "[$(timestamp)] Skipping (Exempt Region): ${tg_target} in ${current_region}" >> ${LOG}
      idle_time=180
    fi
  else
	  echo "[$(timestamp)] Skipping (Cannot Recruit): ${tg_target}" >> ${LOG}
    idle_time=180
  fi

}


function run_non_recruitment_tg() {

  echo "Queuing up Non-Recruitment Telegram to ${tg_target}."

  wait_time=$(( 30 - $idle_time ))
  if [ $wait_time -gt 0 ]; then
    talk_while_sleeping $wait_time
  fi

  curl_data="nation=${tg_target}&q=region"
  response=$(curl -A "${NS_API_USER_AGENT}" "${NS_API_URL}" --data "$curl_data" --http1.1)

  echo $response | xmllint --format - > /tmp/tgisinregion.xml
  echo "[$(timestamp)] $response" >> ${XML_LOG}

  current_region=$(grep -oP '<REGION>\K[^<]+' /tmp/tgisinregion.xml | tr [:upper:] [:lower:] | tr ' ' '_')

  tnponly=$(cat ${ALLOWED_TGS_DIR}/${tg_datafile}.dat | grep "^tnponly=" | cut -d'=' -f2-)

  if [ $tnponly -eq 1 ]; then
    if [ "$current_region" != "the_north_pacific"]; then
	    echo "[$(timestamp)] Skipping (Out of Region - ${tg_datafile}): ${tg_target} in ${current_region}." >> $ ${LOG}
      idle_time=30
    else
      send_telegram
    fi
  else
    send_telegram
  fi

}


function run_telegram_ops() {

  if [ -s "$TG_QUEUE" ]; then
    top_line=$(head -n 1 "$TG_QUEUE")
    echo "[$(timestamp)] Processing $top_line" >> ${LOG}

    tg_target=$(echo $top_line | cut -d"|" -f1)
    tg_datafile=$(echo $top_line | cut -d"|" -f2)

    tg_type=$(cat ${ALLOWED_TGS_DIR}/${tg_datafile}.dat | grep "^type=" | cut -d'=' -f2-)
    tg_id=$(cat ${ALLOWED_TGS_DIR}/${tg_datafile}.dat | grep "^tgid=" | cut -d'=' -f2-)
    tg_key=$(cat ${ALLOWED_TGS_DIR}/${tg_datafile}.dat | grep "^tgkey=" | cut -d'=' -f2-)

    if [ "$tg_type" == "recruitment" ]; then
      run_recruitment_tg
    else
      run_non_recruitment_tg
    fi

    sed -i '1d' "$TG_QUEUE"

  else
    echo "Nothing in queue.          "
    if [ $idle_time -lt 180 ]; then
      idle_time=$(( $idle_time + 10 ))
    fi
    
    if [ $idle_time -ge 180 ]; then
       echo "[$(timestamp)] Nothing in queue. Idle Time: MAX" >> ${LOG}
    else
       echo "[$(timestamp)] Nothing in queue. Idle Time: ${idle_time}/180" >> ${LOG}
    fi
    
    talk_while_sleeping 10
  fi

}

function talk_while_sleeping(){

   local time=$1

   printf '%s\r' "Sleeping for $time seconds..."
   sleep 1
   time=$(( $time - 1 ))

   for ((i=$time; i>0; i--)); do
      printf '%s\r' "Sleeping for ${i} seconds..."
      sleep 1
   done

}

## MAIN ROUTINE ###

echo "Telegram Runner starting."
echo "=======================================" >> ${LOG}
echo "[$(timestamp)] Telegram Runner starting" >> ${LOG}
while :; do
  sleep 2  #Bonus sleep time just to make sure we're below rate limit.
  run_telegram_ops
done
