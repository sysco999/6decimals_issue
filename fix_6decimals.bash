#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CONFIG — MySQL via ~/.my.cnf (NO user/pass in script)
###############################################################################
JOB_DESC="后付费核销"
JOB_CONFIG_ID=35

MYSQL_BATCH=(mysql --batch --skip-column-names)
MYSQL_TABLE=(mysql -t)

###############################################################################
# HELPERS
###############################################################################
die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  read -r -p "$1 (yes/no): " ans
  [[ "${ans,,}" == "yes" ]]
}

sql_one() {
  "${MYSQL_BATCH[@]}" -e "$1"
}

sql_table() {
  "${MYSQL_TABLE[@]}" -e "$1"
}

calc_diff() {
  awk -v g="$1" -v p="$2" 'BEGIN { printf "%.6f", g - p }'
}

###############################################################################
# INPUTS
###############################################################################
read -r -p "Input customer email: " email
read -r -p "Input billing_cycle: " billing_cycle

[[ -n "$email" ]] || die "email required"
[[ -n "$billing_cycle" ]] || die "billing_cycle required"

date=$(date +%Y%m%d)

###############################################################################
# STEP 1 — FETCH DATA
###############################################################################
echo
echo "STEP 1) Fetching data"
echo "------------------------------------------------------------"

cust_id=$(sql_one "SELECT cust_id FROM customer_profile WHERE email='$email' LIMIT 1;")
[[ -n "$cust_id" ]] || die "Customer not found"

account_id=$(sql_one "SELECT account_id FROM account_customer_relation WHERE customer_id=$cust_id LIMIT 1;")
[[ -n "$account_id" ]] || die "Account not found"

balance=$(sql_one "SELECT BALANCE FROM account_book WHERE ACCOUNT_ID=$account_id;")

read -r gross_amount paid_amount < <(
  sql_one "
    SELECT gross_amount, paid_amount
    FROM bill_statement
    WHERE cust_id=$cust_id AND billing_cycle='$billing_cycle'
    LIMIT 1;
  "
)

[[ -n "$gross_amount" ]] || die "Billing statement not found"

diffrence=$(calc_diff "$gross_amount" "$paid_amount")

echo "Balance   : $balance"
echo "Diffrence : $diffrence"

###############################################################################
# STEP 2 — DISPLAY + BACKUP
###############################################################################
echo
echo "STEP 2) Review variables"
cat <<EOF
date          : $date
email         : $email
billing_cycle : $billing_cycle
cust_id       : $cust_id
account_id    : $account_id
balance       : $balance
gross_amount  : $gross_amount
paid_amount   : $paid_amount
diffrence     : $diffrence
EOF

if confirm "Do you want to BACKUP tables?"; then
  sql_one "CREATE TABLE account_book_bak_$date LIKE account_book;"
  sql_one "INSERT INTO account_book_bak_$date SELECT * FROM account_book;"

  sql_one "CREATE TABLE job_info_$date LIKE job_info;"
  sql_one "INSERT INTO job_info_$date SELECT * FROM job_info;"

  sql_one "CREATE TABLE job_config_$date LIKE job_config;"
  sql_one "INSERT INTO job_config_$date SELECT * FROM job_config;"

  echo "Backups completed."
fi

###############################################################################
# STEP 3 — UPDATE BALANCE
###############################################################################
echo
echo "STEP 3) Update balance"

sql_table "SELECT account_id FROM account_customer_relation WHERE customer_id=$cust_id;"

update_balance_sql="UPDATE account_book SET BALANCE = BALANCE + $diffrence WHERE ACCOUNT_ID=$account_id;"
echo "SQL => $update_balance_sql"

confirm "Confirm balance update?" && sql_one "$update_balance_sql"

###############################################################################
# STEP 4 — JOB TRIGGER
###############################################################################
echo
echo "STEP 4) Job status"

sql_table "SELECT * FROM job_info WHERE job_desc='$JOB_DESC';"
sql_table "SELECT * FROM job_config WHERE id=$JOB_CONFIG_ID;"

old_execute_param=$(sql_one "SELECT execute_param FROM job_config WHERE id=$JOB_CONFIG_ID;")

confirm "Set job_config.execute_param?" &&
sql_one "UPDATE job_config SET execute_param='custId=$cust_id' WHERE id=$JOB_CONFIG_ID;"

confirm "Trigger job execution?" &&
sql_one "UPDATE job_info SET trigger_next_time=0 WHERE job_desc='$JOB_DESC';"

###############################################################################
# STEP 5 — RECHECK BILLING
###############################################################################
echo
echo "STEP 5) Re-check billing"

sql_table "
SELECT gross_amount, paid_amount,
       gross_amount - paid_amount AS diff
FROM bill_statement
WHERE cust_id=$cust_id AND billing_cycle='$billing_cycle';
"

###############################################################################
# WAIT 1 MINUTE BEFORE ROLLBACK
###############################################################################
echo "Waiting 60 seconds before STEP 6 (rollback job_config.execute_param)..."
echo "This allows the 后付费核销 job time to execute."

for i in {60..1}; do
  printf "\rRollback in %02d seconds..." "$i"
  sleep 1
done
echo

echo "Wait completed."

###############################################################################
# STEP 6 — ROLLBACK JOB PARAM
###############################################################################
echo
echo "STEP 6) Rollback job_config.execute_param"

rollback_sql="UPDATE job_config SET execute_param='$old_execute_param' WHERE id=$JOB_CONFIG_ID;"
echo "SQL => $rollback_sql"

confirm "Confirm rollback?" && sql_one "$rollback_sql"

###############################################################################
# STEP 7 — FINAL SUMMARY
###############################################################################
echo
echo "STEP 7) Final state"

balance=$(sql_one "SELECT BALANCE FROM account_book WHERE ACCOUNT_ID=$account_id;")

read -r gross_amount paid_amount < <(
  sql_one "
    SELECT gross_amount, paid_amount
    FROM bill_statement
    WHERE cust_id=$cust_id AND billing_cycle='$billing_cycle'
    LIMIT 1;
  "
)

diffrence=$(calc_diff "$gross_amount" "$paid_amount")

cat <<EOF
FINAL STATE
-----------
email         : $email
billing_cycle : $billing_cycle
cust_id       : $cust_id
account_id    : $account_id
balance       : $balance
gross_amount  : $gross_amount
paid_amount   : $paid_amount
diffrence     : $diffrence
EOF

echo "DONE."
