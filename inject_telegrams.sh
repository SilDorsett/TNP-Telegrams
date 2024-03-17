#!/bin/bash

DATA_HOME=${HOME}/.data/tgsystem

tg_type=$1
target_list=${DATA_HOME}/target_lists/$2.txt

while read -r target_nation; do
   echo "${target_nation}|${tg_type}"
   echo "${target_nation}|${tg_type}" >> ${DATA_HOME}/telegram_queue.dat
done < ${target_list}
