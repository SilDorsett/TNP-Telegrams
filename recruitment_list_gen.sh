#!/bin/bash

SCRIPT_HOME="$(cd -- "$MY_PATH" && pwd)"

DATA_HOME=${HOME}/.data/tgsystem

LOGS_HOME=${HOME}/logs/tgsystem
LOG=${LOGS_HOME}/recruitment_list_gen.log
API_LOG=${LOGS_HOME}/recruitment_list_gen_api.log

BANNED_WORDS_FILE=${DATA_HOME}/banned_words.dat

OPTIMAL_QUEUE_DEPTH=$(cat ${DATA_HOME}/queue_depth_settings.dat|grep "OPTIMAL"|cut -d'=' -f2)
HIGH_QUEUE_DEPTH=$(cat ${DATA_HOME}/queue_depth_settings.dat|grep "HIGH"|cut -d'=' -f2)

SINCETIME=9999999999

timestamp() {
  echo -n "$(date '+%Y-%m-%d %H:%M:%S')"
}

reset_queue_depth_alerts() {
   if [ $HIGH_QUEUE_DEPTH -le $OPTIMAL_QUEUE_DEPTH ]; then
      echo "[$(timestamp)] [WARNING] queue_depth_settings.dat has a HIGH value lower or equal to the OPTIMAL value" >> ${LOG}
      HIGH_QUEUE_DEPTH=$(($OPTIMAL_QUEUE_DEPTH + 1))
   fi

   echo "[$(timestamp)] Queue Depth Settings - Optimal: $OPTIMAL_QUEUE_DEPTH, High: $HIGH_QUEUE_DEPTH" >> ${LOG}
}


startup() {

   SINCETIME=$(date +%s)
   #echo $(date +%s) > ~/.data/last_global_foundings_check.txt
   echo "Script is starting up. First check of new (re)foundings in 3 minutes."
   echo "====================================" >> ${LOG}
   echo "[$(timestamp)] Script is starting up. First check of new (re)foundings in 3 minutes." >> ${LOG}
  
   if [ ! -d ${DATA_HOME} ]; then
      mkdir -p ${DATA_HOME}
   fi
   if [ ! -d ${LOGS_HOME} ]; then
      mkdir -p ${LOGS_HOME}
   fi
   if [ ! -f ${DATA_HOME}/telegram_queue.dat ]; then
      touch ${DATA_HOME}/telegram_queue.dat
   fi

   touch ${LOG}
   touch ${API_LOG}

   EL_SPREADSHEET_ID=$(cat ${DATA_HOME}/exclusionlist.dat | grep "^ID=" | cut -d'=' -f2-)
   EL_RANGE_NAME=$(cat ${DATA_HOME}/exclusionlist.dat | grep "^Range=" | cut -d'=' -f2-)
   EL_GOOGLE_SHEETS_KEY_FILE=$(cat ${DATA_HOME}/exclusionlist.dat | grep "^KeyFile=" | cut -d'=' -f2-)
}

update_core_files() {

   # This Spreadsheet has a list of the Delegate, VD, and SC members.
   #SPREADSHEET_ID="1dLcrxoMMXfghkn9rO-qMkwldCay_k9V_zX2_gHnvDxs"
   #RANGE_NAME="Sheet1!A1:A"
      
   range_value=$(python $SCRIPT_HOME/read_exclusion_list.py $SPREADSHEET_ID $RANGE_NAME $GOOGLE_SHEETS_KEY_FILE)
   range_value=$(echo "$range_value" | awk '!seen[$0]++')

   if [ ! "$range_value" == "No data found." ]; then
      if [ ! -z "$range_value" ]; then
         echo "[$(timestamp)] Updated list of excluded regions" >> ${LOG}
         #echo "$range_value"
         echo "$range_value" > ${DATA_HOME}/recruitment_exclusion_list.txt
      else
         echo "[$(timestamp)] Problem updating recruitment exclusion list." ${LOG}
      fi
   else
      echo "[$(timestamp)] Problem updating recruitment exclusion list." ${LOG}
   fi

   banned_words=()
   # Read the banned words into a while loop
   while IFS= read -r word || [ -n "$word" ]; do
#	   echo "Adding word: $word to ban list"
	   banned_words+=("$word")
   done < $BANNED_WORDS_FILE

   #echo "Banned word list is: ${banned_words[@]}"

   reset_queue_depth_alerts
}

contains_banned_word() {
    local value="$1"
    for word in "${banned_words[@]}"; do
        case $value in
            *"$word"*) return 0 ;;  # Return true if a banned word is found
        esac
    done
    return 1  # Return false if no banned word is found
}

add_nation_to_array() {
   local target_nation="$1"
   target_array+=("${target_nation}")
}

queue_up_random_two() {
	local array=("$@")
	local length=${#array[@]}

	if ((length == 0)); then
	   echo "[$(timestamp)] No targets found." >> ${LOG}
	   return
	fi

	if ((length == 1)); then
	   echo "[$(timestamp)] Recruiting: ${array[0]}" >> ${LOG}
	   echo "${array[0]}|recruitment" >> ~/.data/tgsystem/telegram_queue.dat
	   return
	fi

	if ((length >= 2)); then
	   local index1=$((RANDOM % length))
	   local index2=$((RANDOM % length))
  	   while ((index2 == index1)); do
	      index2=$((RANDOM % length))
  	   done

	   for target in ${array[index1]} ${array[index2]}; do
	      echo "[$(timestamp)] Recruiting: ${target}" >> ${LOG}
              echo "${target}|recruitment" >> ~/.data/tgsystem/telegram_queue.dat
           done
	fi
}

queue_up_random_one() {
        local array=("$@")
        local length=${#array[@]}

        if ((length == 0)); then
           echo "[$(timestamp)] No targets found." >> ${LOG}
           return
        fi

        if ((length == 1)); then
           echo "[$(timestamp)] Recruiting: ${array[0]}" >> ${LOG}
           echo "${array[0]}|recruitment" >> ~/.data/tgsystem/telegram_queue.dat
           return
        fi

        if ((length >= 2)); then
           local index=$((RANDOM % length))
           
	   for target in "${array[index]}"; do
              echo "[$(timestamp)] Recruiting: ${target}" >> ${LOG}
              echo "${target}|recruitment" >> ~/.data/tgsystem/telegram_queue.dat
           done
        fi
}


global_foundings() {
   
   #SINCE_TIMESTAMP=$(cat ~/.data/last_global_foundings_check.txt)

   target_array=()

   url="https://www.nationstates.net/cgi-bin/api.cgi"
   curl_data="q=happenings;filter=founding"
   curl_timestamp="sincetime="

   curl_prepare="${curl_data};${curl_timestamp}${SINCETIME}"

   echo "[$(timestamp)] Calling ${url}?${curl_prepare}" >> ${LOG}

   response=$(curl -A "Sil Dorsett" "$url" --data "$curl_prepare" --http1.1)

   echo $response | xmllint --format - > /tmp/global_foundings.${SINCETIME}.xml
   echo "[$(timestamp)] $response" >> ${API_LOG}

   pattern="^.*[^0-9]$"

   while read -r line; do
      if [[ $line =~ \<TEXT\>\<\!\[CDATA\[.*was\ founded\ in.*\]\]\>\<\/TEXT\> ]]; then
         found_nation=$(echo "$line" | grep -oP '@@(.+)@@' | sed 's/@@//g')
         found_region=$(echo "$line" | grep -oP '%%(.+)%%' | sed 's/%%//g')
	 echo "[$(timestamp)] Found: $found_nation founded in $found_region." >> ${LOG}
         if ! grep -q "^${found_region}$" ${DATA_HOME}/recruitment_exclusion_list.txt; then
             if [[ $found_nation =~ $pattern ]]; then
		     if contains_banned_word "$found_nation"; then
			     echo "[$(timestamp)] Skipping (Banned Word): ${found_nation}" >> ${LOG}
		     else
			     echo "[$(timestamp)] Adding to Target Array: ${found_nation}" >> ${LOG}
			     add_nation_to_array "$found_nation"
			     #echo "${found_nation}|recruitment" >> ${DATA_HOME}/telegram_queue.dat
		     fi
             else
		     echo "[$(timestamp)] Skipping (Puppet): ${found_nation}" >> ${LOG}
             fi
         
         else
            echo "[$(timestamp)] Skipping (Region Exempt): $found_nation" >> ${LOG}
         fi
      elif [[ $line =~ \<TEXT\>\<\!\[CDATA\[.*was\ refounded\ in.*\]\]\>\<\/TEXT\> ]]; then
         found_nation=$(echo "$line" | grep -oP '@@(.+)@@' | sed 's/@@//g')
         found_region=$(echo "$line" | grep -oP '%%(.+)%%' | sed 's/%%//g')
	 echo "[$(timestamp)] Found: $found_nation refounded in $found_region." >> ${LOG}
         if ! grep -q "^${found_region}$" ~/.data/tgsystem/recruitment_exclusion_list.txt; then
             if [[ $found_nation =~ $pattern ]]; then
		      if contains_banned_word "$found_nation"; then
                         echo "[$(timestamp)] Skipping (Banned Word): ${found_nation}" >> ${LOG}
                      else
                             echo "[$(timestamp)] Adding to Target Array: ${found_nation}" >> ${LOG}
                             add_nation_to_array "$found_nation"
			     #echo "${found_nation}|recruitment" >> ~/.data/tgsystem/telegram_queue.dat
		      fi
             else
		     echo "[$(timestamp)] Skipping (Puppet): ${found_nation}" >> ${LOG}
             fi
	 else
	    echo "[$(timestamp)] Skipping (Region Exempt): $found_nation" >> ${LOG}
         fi
      fi
   done < /tmp/global_foundings.${SINCETIME}.xml
   rm /tmp/global_foundings.${SINCETIME}.xml

   echo "Dumped foundings after ${SINCETIME}"
   echo "[$(timestamp)] Dumped foundings after ${SINCETIME}" >> ${LOG}

   queue_size=$(cat ~/.data/tgsystem/telegram_queue.dat | wc -l)
#   echo "[$(timestamp)] Current Queue Depth: $queue_size" >> ${LOG}

   target_array_length=${#target_array[@]}
   if [ $target_array_length -gt 0 ]; then
      if [ $queue_size -lt $OPTIMAL_QUEUE_DEPTH ] ; then
           echo "[$(timestamp)] Current Queue Depth: $queue_size (Low, No Limit)" >> ${LOG}
   	   for array_nation in "${target_array[@]}";do
		   echo "[$(timestamp)] Recruiting ${array_nation}" >> ${LOG}
		   echo "${array_nation}|recruitment" >> ~/.data/tgsystem/telegram_queue.dat
	   done
      elif [ $queue_size -ge $OPTIMAL_QUEUE_DEPTH ] && [ $queue_size -lt $HIGH_QUEUE_DEPTH ]; then
           echo "[$(timestamp)] Current Queue Depth: $queue_size (Optimal, Limit 2)" >> ${LOG}
           queue_up_random_two "${target_array[@]}"
      else
           echo "[$(timestamp)] Current Queue Depth: $queue_size (High, Limit 1)" >> ${LOG}
           queue_up_random_one "${target_array[@]}"
      fi
   else
	echo "[$(timestamp)] No targets found in this iteration." >> ${LOG}
	echo "[$(timestamp)] Current Queue Depth: $queue_size (No Targets)" >> ${LOG}
   fi


   SINCETIME=$(date +%s)
   #echo $(date +%s) > ~/.data/last_global_foundings_check.txt

}

talk_while_sleeping(){

   local time=$1

   printf '%s\r' "Sleeping for $time seconds..."
   sleep 1
   time=$(( $time - 1 ))

   for ((i=$time; i>0; i--)); do
      printf '%s\r' "Sleeping for ${i} seconds..."
      sleep 1
   done
}


### Main Routine ###
startup
while :; do
   update_core_files
   talk_while_sleeping 180
   global_foundings
done
