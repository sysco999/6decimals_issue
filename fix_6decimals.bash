#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Config
###############################################################################
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-YOUR_DB_NAME}"
DB_USER="${DB_USER:-root}"

# If you use ~/.my.cnf, you can leave DB_PASS empty and it will just work.
DB_PASS="${DB_PASS:-}"

JOB_DESC="后付费核销"
JOB_CONFIG_ID="35"

# MySQL command builders
mysql_base_args=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME")
if [[ -n "$DB_PASS" ]]; then
  mysql_base_args+=(-p"$DB_PASS")
fi

MYSQL_BATCH=(mysql "${mysql_base_args[@]}" --batch --raw --skip-column-names)
MYSQL_TABLE=(mysql "${mysql_base_args[@]}" -t)

###############################################################################
# Helpers
###############################################################################
die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  local ans
  read -r -p "$prompt (yes/no): " ans
  [[ "${ans,,}" == "yes" ]]
}

run_sql_batch() {
  # prints raw results (no headers)
  local sql="$1"
  "${MYSQL_BATCH[@]}" -e "$sql"
}

run_sql_table() {
  # prints pretty table
  local sql="$1"
  "${MYSQL_TABLE[@]}" -e "$sql"
}

show_vars() {
  echo "--------------------"
  echo "date         : $date"
  echo "email        : $email"
  echo "billing_cycle: $billing_cycle"
  echo "cust_id      : $cust_id"
  echo "account_id   : $account_id"
  echo "balance      : $balance"
  echo "gross_amount : $gross_amount"
  echo "paid_amount  : $paid_amount"
  echo "diffrence    : $diffrence"
  echo "--------------------"
}

calc_diff_6() {
  # input: gross paid
  # output: diff to 6 decimals
  local gross="$1"
  local paid="$2"
  awk -v g="$gross" -v p="$paid" 'BEGIN { printf "%.6f", (g - p) }'
}

###############################################################################
# Inputs
###############################################################################
read -r -p "Input customer email: " email
[[ -n "$email" ]] || die "email is required"

read -r -p "Input billing_cycle: " billing_cycle
[[ -n "$billing_cycle" ]] || die "billing_cycle is required"

date="$(date +%Y%m%d)"

###############################################################################
# Step 1: Fetch variables & compute diffrence
###############################################################################
echo
echo "STEP 1) Fetch cust_id, account_id, balance, gross/paid, compute diffrence"
echo "------------------------------------------------------------"

# cust_id (as you requested: select cust_id from customer_profile ...)
cust_id="$(run_sql_batch "SELECT cust_id FROM customer_profile WHERE email='${email}' LIMIT 1;")"
[[ -n "$cust_id" ]] || die "No cust_id found in customer_profile for email='$email'"

# account_id (customer_id = cust_id)
account_id="$(run_sql_batch "SELECT account_id FROM account_customer_relation WHERE customer_id=${cust_id} LIMIT 1;")"
[[ -n "$account_id" ]] || die "No account_id found in account_customer_relation for customer_id=$cust_id"

# balance
balance="$(run_sql_batch "SELECT BALANCE FROM account_book WHERE ACCOUNT_ID=${account_id} LIMIT 1;")"
[[ -n "$balance" ]] || die "No BALANCE found in account_book for ACCOUNT_ID=$account_id"

# billing statement gross/paid (use SUM in case multiple rows)
read -r gross_amount paid_amount < <(
  run_sql_batch "
    SELECT
      IFNULL(ROUND(SUM(gross_amount), 6), 0.000000) AS gross_amount,
      IFNULL(ROUND(SUM(paid_amount), 6), 0.000000)  AS paid_amount
    FROM bill_statement
    WHERE cust_id=${cust_id}
      AND billing_cycle='${billing_cycle}';
  " | head -n 1
)

gross_amount="${gross_amount:-0.000000}"
paid_amount="${paid_amount:-0.000000}"

diffrence="$(calc_diff_6 "$gross_amount" "$paid_amount")"

echo "Balance   : $balance"
echo "Diffrence : $diffrence"
echo

###############################################################################
# Step 2: Display variables and ask for backup
###############################################################################
echo "STEP 2) Display all variables then optional backups"
echo "------------------------------------------------------------"
show_vars

if confirm "Do you want to BACKUP tables (account_book, job_info, job_config) with suffix $date?"; then
  echo
  echo "Running backups..."

  # Show the backup SQL (informational)
  echo "SQL => create table account_book_bak_${date} like account_book;"
  echo "SQL => insert into account_book_bak_${date} select * from account_book;"
  echo "SQL => create table job_info_${date} like job_info;"
  echo "SQL => insert into job_info_${date} select * from job_info;"
  echo "SQL => create table job_config_${date} like job_config;"
  echo "SQL => insert into job_config_${date} select * from job_config;"
  echo

  run_sql_batch "CREATE TABLE account_book_bak_${date} LIKE account_book;"
  run_sql_batch "INSERT INTO account_book_bak_${date} SELECT * FROM account_book;"

  run_sql_batch "CREATE TABLE job_info_${date} LIKE job_info;"
  run_sql_batch "INSERT INTO job_info_${date} SELECT * FROM job_info;"

  run_sql_batch "CREATE TABLE job_config_${date} LIKE job_config;"
  run_sql_batch "INSERT INTO job_config_${date} SELECT * FROM job_config;"

  echo "Backups done."
else
  echo "Backup skipped."
fi

echo

###############################################################################
# Step 3: Re-check account_id and confirm balance update
###############################################################################
echo "STEP 3) Confirm account_id & diffrence, then update account_book"
echo "------------------------------------------------------------"

echo "Re-checking account_id using: select account_id from account_customer_relation where customer_id=$cust_id;"
run_sql_table "SELECT account_id FROM account_customer_relation WHERE customer_id=${cust_id};"
echo

echo "account_id = $account_id"
echo "diffrence  = $diffrence"
echo

update_balance_sql="UPDATE account_book SET BALANCE = BALANCE + ${diffrence} WHERE ACCOUNT_ID = ${account_id};"
echo "About to run SQL:"
echo "$update_balance_sql"
echo

if confirm "Confirm UPDATE balance?"; then
  run_sql_batch "$update_balance_sql"
  echo "Balance updated."
else
  echo "Balance update skipped."
fi

# Refresh balance after update
balance="$(run_sql_batch "SELECT BALANCE FROM account_book WHERE ACCOUNT_ID=${account_id} LIMIT 1;")"
echo "New balance: $balance"
echo

###############################################################################
# Step 4: Check job status + confirm job_config/job_info updates
###############################################################################
echo "STEP 4) Check job_info/job_config, then set params & trigger"
echo "------------------------------------------------------------"

echo "Running:"
echo "select * from job_info where job_desc='${JOB_DESC}';"
echo "select * from job_config where id=${JOB_CONFIG_ID};"
echo

run_sql_table "SELECT * FROM job_info WHERE job_desc='${JOB_DESC}';"
run_sql_table "SELECT * FROM job_config WHERE id=${JOB_CONFIG_ID};"
echo

# Save old execute_param to rollback to older state safely
old_execute_param="$(run_sql_batch "SELECT execute_param FROM job_config WHERE id=${JOB_CONFIG_ID} LIMIT 1;")"
old_execute_param="${old_execute_param:-}"

echo "cust_id = $cust_id"
echo

sql_set_param="UPDATE job_config SET execute_param='custId=${cust_id}' WHERE id=${JOB_CONFIG_ID};"
echo "About to run SQL:"
echo "$sql_set_param"
if confirm "Confirm update job_config.execute_param?"; then
  run_sql_batch "$sql_set_param"
  echo "job_config updated."
else
  echo "job_config update skipped."
fi
echo

sql_trigger="UPDATE job_info SET trigger_next_time = 0 WHERE job_desc='${JOB_DESC}';"
echo "About to run SQL:"
echo "$sql_trigger"
if confirm "Confirm update job_info.trigger_next_time=0?"; then
  run_sql_batch "$sql_trigger"
  echo "job_info trigger updated."
else
  echo "job_info trigger update skipped."
fi
echo

###############################################################################
# Step 5: Re-check bill_statement gross/paid
###############################################################################
echo "STEP 5) Re-check billing statement gross/paid"
echo "------------------------------------------------------------"
echo "Running:"
echo "select gross_amount, paid_amount from bill_statement where cust_id=$cust_id and billing_cycle='$billing_cycle';"
echo

run_sql_table "
  SELECT gross_amount, paid_amount
  FROM bill_statement
  WHERE cust_id=${cust_id}
    AND billing_cycle='${billing_cycle}';
"
echo

###############################################################################
# Step 6: Roll back job parameter to older state
###############################################################################
echo "STEP 6) Rollback job_config.execute_param to older state"
echo "------------------------------------------------------------"

# Your algorithm says: update job_config set execute_param='';
# Safer: restore the previous value we captured.
rollback_sql="UPDATE job_config SET execute_param='${old_execute_param//\'/\\\'}' WHERE id=${JOB_CONFIG_ID};"

echo "About to run SQL (rollback):"
echo "$rollback_sql"
echo

if confirm "Confirm rollback execute_param to previous value?"; then
  run_sql_batch "$rollback_sql"
  echo "Rollback done."
else
  echo "Rollback skipped."
fi
echo


echo
echo "Waiting 60 seconds before STEP 6 (rollback job_config.execute_param)..."
echo "This allows the 后付费核销 job time to execute."

for i in {60..1}; do
  printf "\rRollback in %02d seconds..." "$i"
  sleep 1
done
echo

echo "Wait completed."

###############################################################################
# Step 7: Display everything
###############################################################################
echo "STEP 7) Final summary"
echo "------------------------------------------------------------"

# Refresh gross/paid and diff again for final display
read -r gross_amount paid_amount < <(
  run_sql_batch "
    SELECT
      IFNULL(ROUND(SUM(gross_amount), 6), 0.000000) AS gross_amount,
      IFNULL(ROUND(SUM(paid_amount), 6), 0.000000)  AS paid_amount
    FROM bill_statement
    WHERE cust_id=${cust_id}
      AND billing_cycle='${billing_cycle}';
  " | head -n 1
)
gross_amount="${gross_amount:-0.000000}"
paid_amount="${paid_amount:-0.000000}"
diffrence="$(calc_diff_6 "$gross_amount" "$paid_amount")"

show_vars

echo "Done."
