#!/bin/bash
day_of_year=$(date +%-j)
week_of_year=$(date +%-V)

# Days in this year (365 or 366)
year=$(date +%Y)
if (( year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) )); then
  days_in_year=366
else
  days_in_year=365
fi
days_left=$((days_in_year - day_of_year))

# ISO weeks in this year (52 or 53)
# Last day of the year's ISO week number tells us
last_week=$(date -d "${year}-12-28" +%-V)
weeks_left=$((last_week - week_of_year))

date "+%a %H:%M:%S %m/%d ${day_of_year}|${days_left} ${week_of_year}|${weeks_left}" | awk '{print $1, $3, $2, $4, $5}'
